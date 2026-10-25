import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:floresta_gui/core/electrum/electrum_client.dart';
import 'package:floresta_gui/core/electrum/electrum_transport.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/wallet/data/bip32_address_deriver.dart';
import 'package:floresta_gui/features/wallet/data/transaction_verification.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_sync_ports.dart';
import 'package:fpdart/fpdart.dart';

/// Public vectors produced by Bitcoin Core (tool/regtest/generate_test_fixtures.py).
final Map<String, Object?> walletVectors =
    jsonDecode(File('test/fixtures/wallet_vectors.json').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> vectorType(String kind) =>
    (walletVectors['types'] as Map)[kind] as Map<String, Object?>;

Map<String, Object?> get chainVectors =>
    walletVectors['chain'] as Map<String, Object?>;

List<Map<String, Object?>> get chainTxs =>
    (chainVectors['transactions'] as List).cast<Map<String, Object?>>();

Map<int, String> get chainBlockHashes => (chainVectors['block_hashes'] as Map)
    .map((k, v) => MapEntry(int.parse(k as String), v as String));

int btcToSats(num btc) => (btc * 1e8).round();

/// Electrum server double backed by the Core fixture chain. Histories map
/// scripthash → entries; raw data per txid. Mutable to script scenarios.
class FixtureElectrumClient implements ElectrumClient {
  FixtureElectrumClient({String? genesis})
    : genesisHash = genesis ?? chainBlockHashes[0]! {
    for (final t in chainTxs) {
      raws[t['txid'] as String] = t['raw'] as String;
      final m = t['merkle'] as Map;
      merkles[t['txid'] as String] = MerkleProof(
        blockHeight: m['block_height'] as int,
        position: m['pos'] as int,
        siblings: (m['siblings'] as List).cast<String>(),
      );
      headers[t['height'] as int] = t['header'] as String;
    }
  }

  String genesisHash;
  final histories = <String, List<HistoryEntry>>{};
  final raws = <String, String>{};
  final merkles = <String, MerkleProof>{};
  final headers = <int, String>{};
  final calls = <String>[];
  bool connected = false;
  bool failNextConnect = false;
  final _events = StreamController<ElectrumEvent>.broadcast();
  final _drops = StreamController<Object?>.broadcast();

  /// Indexes every fixture transaction under the scripts it pays or spends.
  void indexFixtureChain(Iterable<String> ownScripts) {
    final own = ownScripts.toSet();
    final outputs = <String, String>{}; // "txid:vout" -> spk
    for (final t in chainTxs) {
      final tx = TransactionVerification.parse(
        t['txid'] as String,
        t['raw'] as String,
      )!;
      for (final o in tx.outputs) {
        outputs['${tx.txid}:${o.vout}'] = o.scriptPubKey;
      }
    }
    for (final t in chainTxs) {
      final tx = TransactionVerification.parse(
        t['txid'] as String,
        t['raw'] as String,
      )!;
      final touched = <String>{
        for (final o in tx.outputs)
          if (own.contains(o.scriptPubKey)) o.scriptPubKey,
        for (final i in tx.inputs)
          if (own.contains(outputs['${i.txid}:${i.vout}']))
            outputs['${i.txid}:${i.vout}']!,
      };
      for (final spk in touched) {
        histories
            .putIfAbsent(electrumScripthash(spk), () => [])
            .add(HistoryEntry(tx.txid, t['height'] as int));
      }
    }
  }

  void notify(ElectrumEvent e) => _events.add(e);
  void drop() {
    connected = false;
    _drops.add(null);
  }

  void _ensure(String m) {
    calls.add(m);
    if (!connected) throw ElectrumConnectionException(m, 'not connected');
  }

  @override
  String get endpoint => 'fixture:0';
  @override
  bool get isConnected => connected;
  @override
  Stream<ElectrumEvent> get events => _events.stream;
  @override
  Stream<Object?> get disconnects => _drops.stream;

  @override
  Future<void> connect() async {
    calls.add('connect');
    if (failNextConnect) {
      failNextConnect = false;
      throw const ElectrumConnectionException('connect', 'refused');
    }
    connected = true;
  }

  @override
  Future<ServerFeatures> handshake() async {
    _ensure('handshake');
    return ServerFeatures(
      serverVersion: 'Floresta 0.5.1',
      protocolVersion: '1.4',
      genesisHash: genesisHash,
    );
  }

  @override
  Future<HeaderTip> subscribeHeaders() async {
    _ensure('headers.subscribe');
    final h = headers.keys.fold(0, (a, b) => a > b ? a : b);
    return HeaderTip(h, headers[h]!);
  }

  @override
  Future<String> blockHeader(int height) async {
    _ensure('block.header');
    final h = headers[height];
    if (h == null) throw ElectrumServerException('block.header', -1, 'none');
    return h;
  }

  @override
  Future<Map<String, String?>> subscribeScripthashes(
    List<String> hashes,
  ) async {
    _ensure('scripthash.subscribe');
    return {
      for (final h in hashes)
        h: TransactionVerification.electrumStatus(histories[h] ?? const []),
    };
  }

  @override
  Future<List<HistoryEntry>> history(String scripthash) async {
    _ensure('get_history');
    return List.of(histories[scripthash] ?? const []);
  }

  @override
  Future<Map<String, String>> transactions(List<String> txids) async {
    _ensure('transaction.get');
    return {for (final t in txids) t: raws[t]!};
  }

  @override
  Future<MerkleProof> merkle(String txid, int height) async {
    _ensure('get_merkle');
    final m = merkles[txid];
    if (m == null) throw ElectrumServerException('get_merkle', -1, 'none');
    return m;
  }

  @override
  Future<void> close() async => connected = false;
}

class FixtureChainView implements ChainView {
  FixtureChainView() : hashes = Map.of(chainBlockHashes);
  final Map<int, String> hashes;
  int? validatedOverride;
  bool unreachable = false;

  int get tip => hashes.keys.fold(0, (a, b) => a > b ? a : b);

  @override
  Future<Either<Failure, ({int validatedHeight, bool ibd})>> status() async =>
      unreachable
      ? const Left(RpcUnreachableFailure('127.0.0.1:0'))
      : Right((validatedHeight: validatedOverride ?? tip, ibd: false));

  @override
  Future<Either<Failure, String>> blockHash(int height) async =>
      hashes.containsKey(height) && !unreachable
      ? Right(hashes[height]!)
      : const Left(RpcUnreachableFailure('127.0.0.1:0'));
}

class MemoryWalletStore implements WalletStore {
  final data = <String, WalletSyncData>{};
  int saves = 0;
  @override
  Future<Either<Failure, WalletSyncData>> load(String id) async =>
      Right(data[id] ?? const WalletSyncData());
  @override
  Future<Either<Failure, Unit>> save(String id, WalletSyncData d) async {
    saves++;
    data[id] = d;
    return const Right(unit);
  }
}
