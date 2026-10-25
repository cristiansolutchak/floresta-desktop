import 'dart:async';
import 'dart:math';

import 'package:fpdart/fpdart.dart';

import '../../../core/electrum/electrum_client.dart';
import '../../../core/electrum/electrum_transport.dart';
import '../../../core/errors/failure.dart';
import '../domain/balance_calculator.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_state.dart';
import '../domain/wallet_sync_ports.dart';
import 'transaction_verification.dart';

/// Counters for one sync pass; used by tests and diagnostics.
class SyncStats {
  int scriptsSubscribed = 0;
  int historiesFetched = 0;
  int transactionsFetched = 0;
  int merkleChecks = 0;
  int rejectedTransactions = 0;
  int unverifiedEntries = 0;
  int statusMismatches = 0;
  bool reorgDetected = false;

  /// Time spent waiting for the Electrum server to index new blocks.
  Duration indexingWait = Duration.zero;
  @override
  String toString() =>
      'SyncStats(subscribed: $scriptsSubscribed, histories: $historiesFetched, '
      'txs: $transactionsFetched, merkle: $merkleChecks, rejected: '
      '$rejectedTransactions, unverified: $unverifiedEntries, statusMismatch: '
      '$statusMismatches, reorg: $reorgDetected, indexingWait: $indexingWait)';
}

/// Synchronises one watch-only account from Floresta's Electrum server.
///
/// Trust model (ADR-0007): Electrum answers are claims. A transaction counts
/// as confirmed only if its raw bytes hash to its txid, its merkle path
/// matches the header at its height, and that header's hash equals the
/// block hash florestad's RPC reports for the height. This also drops
/// transactions orphaned by reorgs, which florestad v0.9.1 keeps serving.
class WalletSyncEngine {
  WalletSyncEngine({
    required this.account,
    required this.client,
    required this.chain,
    required this.store,
    required AddressDeriver deriver,
    this.coverage = 100,
    this.indexingGrace = const Duration(milliseconds: 1500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _headerWatch = client.events.listen((e) {
      if (e is NewHeader) {
        if (e.tip.height > _notifiedHeight) _notifiedHeight = e.tip.height;
        if (!_headerSignal.isClosed) _headerSignal.add(e.tip.height);
      }
    });
    _scripts = [
      for (final k in Keychain.values)
        for (var i = 0; i < coverage; i++)
          deriver.derive(account.descriptor(k), i),
    ];
    _ownScripts = {for (final s in _scripts) s.scriptPubKey};
    _current = WalletSnapshot(
      accountId: account.id,
      balance: null,
      transactions: const [],
      sync: const SyncNotStarted(),
      coverageLimit: coverage,
    );
  }

  final WalletAccount account;
  final ElectrumClient client;
  final ChainView chain;
  final WalletStore store;

  /// Addresses watched per keychain; florestad v0.9.1 watches exactly 100.
  final int coverage;

  /// How long to stay silent on Electrum when the node has validated a block
  /// the server has not announced yet.
  ///
  /// florestad v0.9.1's Electrum main loop indexes queued blocks only after a
  /// full second without client messages (`electrum_protocol.rs`
  /// `main_loop`: `timeout(1s, recv)`), so querying sooner returns pre-block
  /// history, and querying more often than once a second starves indexing.
  /// Its `headers.subscribe` notification is written immediately before the
  /// block is indexed, so receiving it is a sufficient barrier.
  final Duration indexingGrace;
  final DateTime Function() _clock;
  late final StreamSubscription<ElectrumEvent> _headerWatch;
  final _headerSignal = StreamController<int>.broadcast();
  int _notifiedHeight = -1;
  int _graceSatisfiedHeight = -1;

  late final List<DerivedScript> _scripts;
  late final Set<String> _ownScripts;
  WalletSyncData? _data;
  late WalletSnapshot _current;
  DateTime? _lastSuccess;
  Future<Either<Failure, WalletSnapshot>>? _running;
  bool _rerun = false;
  SyncStats lastStats = SyncStats();

  final _snapshots = StreamController<WalletSnapshot>.broadcast();
  StreamSubscription<ElectrumEvent>? _events;
  StreamSubscription<Object?>? _drops;
  Timer? _debounce;
  Timer? _retry;
  int _retryAttempt = 0;
  bool _live = false;

  List<DerivedScript> get scripts => List.unmodifiable(_scripts);
  WalletSnapshot get current => _current;
  Stream<WalletSnapshot> get snapshots => _snapshots.stream;

  /// Runs one sync pass. Concurrent calls coalesce into at most one rerun.
  Future<Either<Failure, WalletSnapshot>> syncOnce() {
    final running = _running;
    if (running != null) {
      _rerun = true;
      return running;
    }
    final future = _syncLoop();
    _running = future;
    return future.whenComplete(() => _running = null);
  }

  Future<Either<Failure, WalletSnapshot>> _syncLoop() async {
    Either<Failure, WalletSnapshot> result;
    do {
      _rerun = false;
      result = await _pass();
    } while (_rerun);
    return result;
  }

  Future<Either<Failure, WalletSnapshot>> _pass() async {
    final stats = SyncStats();
    lastStats = stats;
    _emit(
      _current.balance == null ? _withSync(const SyncInProgress()) : _current,
    );
    try {
      return await _syncPass(stats);
    } on ElectrumException catch (e) {
      final failure = switch (e) {
        ElectrumProtocolException(:final detail) => ElectrumProtocolFailure(
          e.method,
          detail,
        ),
        _ => ElectrumUnavailableFailure(client.endpoint, '$e'),
      };
      if (e is ElectrumConnectionException || e is ElectrumTimeoutException) {
        await client.close();
      }
      return Left(_fail(failure));
    } on _AbortSync catch (a) {
      return Left(_fail(a.failure, blocked: a.blocked));
    }
  }

  Future<Either<Failure, WalletSnapshot>> _syncPass(SyncStats stats) async {
    final data = _data ??= (await store.load(account.id)).getOrElse(
      (_) => const WalletSyncData(), // corrupt state: full resync
    );

    // The node's view first (HTTP RPC, does not touch the Electrum loop).
    final node = _unwrap(await chain.status());
    final validated = node.validatedHeight;
    if (validated > max(_notifiedHeight, _graceSatisfiedHeight)) {
      final waited = Stopwatch()..start();
      await _headerSignal.stream
          .firstWhere((h) => h >= validated)
          .timeout(indexingGrace, onTimeout: () => -1);
      stats.indexingWait = waited.elapsed;
      _graceSatisfiedHeight = validated;
    }

    if (!client.isConnected) await client.connect();
    final features = await client.handshake();
    if (features.genesisHash != account.network.genesisHash) {
      throw _AbortSync(
        ChainMismatchFailure(
          'The wallet server is on a chain with genesis '
          '${features.genesisHash}, not ${account.network.label}.',
        ),
        blocked: true,
      );
    }
    final genesis = _unwrap(await chain.blockHash(0));
    if (genesis != account.network.genesisHash) {
      throw _AbortSync(
        ChainMismatchFailure('The node is not on ${account.network.label}.'),
        blocked: true,
      );
    }
    await client.subscribeHeaders();

    // Reorg check against the tip we verified last time.
    final hashCache = <int, String>{};
    Future<String> nodeHash(int h) async =>
        hashCache[h] ??= _unwrap(await chain.blockHash(h));
    var reorg = false;
    final lastTip = data.tip;
    if (lastTip != null) {
      reorg =
          lastTip.height > validated ||
          await nodeHash(lastTip.height) != lastTip.hash;
    }
    stats.reorgDetected = reorg;

    final statuses = await client.subscribeScripthashes([
      for (final s in _scripts) s.scripthash,
    ]);
    stats.scriptsSubscribed = statuses.length;

    final histories = <String, List<HistoryEntry>>{};
    final storedHistories = data.histories;
    for (final s in _scripts) {
      final status = statuses[s.scripthash];
      final unchanged =
          !reorg &&
          data.statuses.containsKey(s.scripthash) &&
          data.statuses[s.scripthash] == status;
      if (unchanged) continue;
      if (status == null) {
        histories[s.scripthash] = const [];
        continue;
      }
      final entries = await client.history(s.scripthash);
      stats.historiesFetched++;
      if (TransactionVerification.electrumStatus(entries) != status) {
        // The history changed between subscribe and fetch; the next status
        // notification will trigger another pass.
        stats.statusMismatches++;
      }
      histories[s.scripthash] = entries;
    }

    // Heights per txid from fresh histories, else from storage.
    final heights = <String, int>{};
    final txidsByScript = <String, List<String>>{};
    for (final s in _scripts) {
      final fresh = histories[s.scripthash];
      if (fresh != null) {
        txidsByScript[s.scripthash] = [for (final e in fresh) e.txid];
        for (final e in fresh) {
          heights[e.txid] = e.height;
        }
      } else {
        final ids = storedHistories[s.scripthash] ?? const [];
        txidsByScript[s.scripthash] = ids;
        for (final id in ids) {
          heights.putIfAbsent(id, () => data.transactions[id]?.height ?? 0);
        }
      }
    }

    final missing = [
      for (final id in heights.keys)
        if (!data.transactions.containsKey(id)) id,
    ];
    final fetched = missing.isEmpty
        ? const <String, String>{}
        : await client.transactions(missing);
    stats.transactionsFetched = fetched.length;

    final parsed = <String, ParsedTransaction>{};
    final stored = <String, StoredTx>{};
    for (final id in heights.keys) {
      final raw = data.transactions[id]?.rawHex ?? fetched[id];
      final tx = raw == null ? null : TransactionVerification.parse(id, raw);
      if (tx == null) {
        stats.rejectedTransactions++;
        continue;
      }
      parsed[id] = tx;
      stored[id] = (data.transactions[id] ?? StoredTx(rawHex: raw!, height: 0));
    }

    // Keep only transactions that touch this wallet's scripts.
    final ownOutpoints = <OutPoint>{
      for (final t in parsed.values)
        for (final o in t.outputs)
          if (_ownScripts.contains(o.scriptPubKey)) OutPoint(t.txid, o.vout),
    };
    parsed.removeWhere((id, t) {
      final relevant =
          t.outputs.any((o) => _ownScripts.contains(o.scriptPubKey)) ||
          t.inputs.any(ownOutpoints.contains);
      if (!relevant) {
        stats.rejectedTransactions++;
        stored.remove(id);
      }
      return !relevant;
    });

    final records = <WalletTxRecord>[];
    for (final MapEntry(key: id, value: tx) in parsed.entries) {
      final height = heights[id] ?? 0;
      final previous = stored[id]!;
      final TxConfirmation confirmation;
      if (height <= 0) {
        confirmation = const Unconfirmed();
        stored[id] = previous.copyWith(height: height, clear: true);
      } else if (height > validated) {
        confirmation = PendingValidation(height);
        stored[id] = previous.copyWith(height: height, clear: true);
      } else {
        final expected = await nodeHash(height);
        if (!reorg &&
            previous.height == height &&
            previous.verifiedBlockHash == expected) {
          confirmation = Confirmed(height, expected);
        } else {
          stats.merkleChecks++;
          confirmation = await _verifyInclusion(id, height, expected);
          if (confirmation is Unverified) stats.unverifiedEntries++;
          stored[id] = previous.copyWith(
            height: height,
            verifiedBlockHash: confirmation is Confirmed ? expected : null,
            clear: confirmation is! Confirmed,
          );
        }
      }
      records.add(WalletTxRecord(tx, confirmation));
    }

    final tipHash = await nodeHash(validated);
    final next = WalletSyncData(
      statuses: statuses,
      histories: txidsByScript,
      transactions: stored,
      tip: (height: validated, hash: tipHash),
    );
    final saved = await store.save(account.id, next);
    if (saved case Left(:final value)) throw _AbortSync(value);
    _data = next;

    final result = BalanceCalculator.compute(
      records: records,
      ownScripts: _ownScripts,
      tipHeight: validated,
    );
    _lastSuccess = _clock();
    _retryAttempt = 0;
    final snapshot = WalletSnapshot(
      accountId: account.id,
      balance: result.balance,
      transactions: result.history,
      sync: SyncUpToDate(validated, _lastSuccess!),
      coverageLimit: coverage,
    );
    _emit(snapshot);
    return Right(snapshot);
  }

  Future<TxConfirmation> _verifyInclusion(
    String txid,
    int height,
    String expectedBlockHash,
  ) async {
    final header = await client.blockHeader(height);
    if (TransactionVerification.headerHash(header) != expectedBlockHash) {
      return Unverified('server header at $height differs from the node');
    }
    final MerkleProof proof;
    try {
      proof = await client.merkle(txid, height);
    } on ElectrumServerException {
      return Unverified('no inclusion proof at height $height');
    }
    if (proof.blockHeight != height ||
        !TransactionVerification.merkleMatches(
          txid: txid,
          proof: proof,
          headerHex: header,
        )) {
      return Unverified('not included in the block at height $height');
    }
    return Confirmed(height, expectedBlockHash);
  }

  T _unwrap<T>(Either<Failure, T> e) =>
      e.match((f) => throw _AbortSync(f), (v) => v);

  Failure _fail(Failure failure, {bool blocked = false}) {
    _emit(
      _withSync(
        blocked ? SyncBlocked(failure) : SyncStale(failure, _lastSuccess),
      ),
    );
    if (_live && !blocked) _scheduleRetry();
    return failure;
  }

  WalletSnapshot _withSync(WalletSyncState s) => WalletSnapshot(
    accountId: _current.accountId,
    balance: _current.balance,
    transactions: _current.transactions,
    sync: s,
    coverageLimit: coverage,
  );

  void _emit(WalletSnapshot s) {
    _current = s;
    if (!_snapshots.isClosed) _snapshots.add(s);
  }

  /// Keeps the wallet current: resyncs on status or header notifications
  /// and reconnects with capped exponential backoff after failures.
  Future<void> start() async {
    if (_live) return;
    _live = true;
    _events = client.events.listen((_) => _scheduleSync());
    _drops = client.disconnects.listen((_) {
      if (_live) _scheduleRetry();
    });
    await syncOnce();
  }

  void _scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), syncOnce);
  }

  void _scheduleRetry() {
    if (_retry?.isActive ?? false) return;
    final seconds = min(30, 1 << min(_retryAttempt, 5));
    _retryAttempt++;
    _retry = Timer(Duration(seconds: seconds), () async {
      if (_live) await syncOnce();
    });
  }

  Future<void> stop() async {
    _live = false;
    _debounce?.cancel();
    _retry?.cancel();
    await _events?.cancel();
    await _drops?.cancel();
    await _running;
  }

  Future<void> dispose() async {
    await stop();
    await _headerWatch.cancel();
    await _headerSignal.close();
    await _snapshots.close();
    await client.close();
  }
}

class _AbortSync implements Exception {
  const _AbortSync(this.failure, {this.blocked = false});
  final Failure failure;
  final bool blocked;
}
