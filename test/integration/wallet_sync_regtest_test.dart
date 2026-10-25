/// Opt-in wallet-sync integration tests against REAL processes:
/// bitcoind (miner + disposable test wallet that owns the keys) → utreexod
/// v0.6.0 bridge → florestad v0.9.1. The app's own registrar, Electrum
/// client and sync engine are exercised; nothing is mocked. Bitcoin Core's
/// wallet accounting for the same keys is the oracle.
///
///   source "$(tool/regtest/bootstrap.sh --print-env)"
///   flutter test test/integration/wallet_sync_regtest_test.dart
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/electrum/electrum_client.dart';
import 'package:floresta_gui/core/electrum/electrum_transport.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/wallet/data/bip32_address_deriver.dart';
import 'package:floresta_gui/features/wallet/data/floresta_watch_registrar.dart';
import 'package:floresta_gui/features/wallet/data/json_file_wallet_store.dart';
import 'package:floresta_gui/features/wallet/data/node_chain_view.dart';
import 'package:floresta_gui/features/wallet/data/single_sig_descriptor_parser.dart';
import 'package:floresta_gui/features/wallet/data/wallet_repository_impl.dart';
import 'package:floresta_gui/features/wallet/data/wallet_sync_engine.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_account.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/regtest_cluster.dart';

final _skip = RegtestCluster.missingTools;

int _sats(Object? btc) => ((btc! as num) * 1e8).round();

void main() {
  late RegtestCluster cluster;
  late WalletAccount account;
  late Directory storeDir;
  late http.Client httpClient;

  ElectrumClient newClient() => TcpElectrumClient(
    ElectrumTransport(host: '127.0.0.1', port: cluster.floElectrum),
  );

  WalletSyncEngine newEngine({ElectrumClient? client, WalletAccount? acct}) =>
      WalletSyncEngine(
        account: acct ?? account,
        client: client ?? newClient(),
        chain: NodeChainView(cluster.floRpcRepo),
        store: JsonFileWalletStore(storeDir),
        deriver: Bip32AddressDeriver(),
      );

  Future<Map<String, Object?>> coreBalances() async =>
      ((await cluster.core.call('getbalances', [], 'subject')) as Map)['mine']
          as Map<String, Object?>;

  /// Core's wallet transactions, excluding entries Core itself marks as
  /// orphaned by a reorg (category "orphan"; never part of any balance).
  Future<Set<String>> coreTxids() async => {
    for (final t
        in (await cluster.core.call('listtransactions', ['*', 1000], 'subject'))
            as List)
      if ((t as Map)['category'] != 'orphan') t['txid'] as String,
  };

  Future<String> subjectAddress({bool change = false}) async =>
      await cluster.core.call(
            change ? 'getrawchangeaddress' : 'getnewaddress',
            change ? ['bech32'] : ['', 'bech32'],
            'subject',
          )
          as String;

  /// Engine balance must equal Core's view of the same keys.
  Future<void> expectMatchesCore(WalletSnapshot snap) async {
    final core = await coreBalances();
    expect(
      snap.balance!.spendable,
      _sats(core['trusted']),
      reason: 'spendable vs Core trusted',
    );
    expect(
      snap.balance!.immature,
      _sats(core['immature']),
      reason: 'immature vs Core',
    );
    expect(snap.balance!.pending, 0);
    final ours = {for (final t in snap.transactions) t.txid};
    expect(ours, await coreTxids(), reason: 'tx set vs Core listtransactions');
  }

  setUpAll(() async {
    if (_skip != null) return;
    cluster = await RegtestCluster.start();
    storeDir = Directory('${cluster.root.path}/wallet-store')..createSync();
    httpClient = http.Client();

    // Public descriptors of Core's disposable "subject" wallet.
    final descs =
        ((await cluster.core.call('listdescriptors', [], 'subject'))
                as Map)['descriptors']
            as List;
    String desc(bool internal) =>
        (descs.firstWhere(
                  (d) =>
                      (d as Map)['desc'].toString().startsWith('wpkh(') &&
                      d['internal'] == internal,
                )
                as Map)['desc']
            as String;
    final parsed = const SingleSigDescriptorParser()
        .parseAccount(desc(false), BitcoinNetwork.regtest)
        .getOrElse((f) => throw StateError(f.message));
    expect(
      parsed.internal.value,
      desc(true),
      reason: 'internal branch must equal Core\'s',
    );
    account = WalletAccount(
      id: 'regtest1',
      network: BitcoinNetwork.regtest,
      external: parsed.external,
      internal: parsed.internal,
    );
  });

  tearDownAll(() async {
    if (_skip != null) return;
    httpClient.close();
    await cluster.dispose();
  });

  group('wallet sync on a real regtest cluster', skip: _skip, () {
    test(
      'registers both branches once, then initial sync matches Core',
      () async {
        final wallet = WalletRepositoryImpl(
          JsonRpcClient(
            endpoint: cluster.floSettings.rpcEndpoint,
            httpClient: httpClient,
          ),
        );
        final registrar = FlorestaWatchRegistrar(wallet);
        expect((await registrar.ensureWatched(account)).toNullable(), 2);
        expect(
          (await registrar.ensureWatched(account)).toNullable(),
          0,
          reason: 'no duplicate import',
        );
        expect((await wallet.listDescriptors()).toNullable(), hasLength(2));

        final a1 = await subjectAddress();
        final a2 = await subjectAddress();
        await cluster.core.call('sendtoaddress', [a1, 1.0], 'miner');
        await cluster.core.call('sendtoaddress', [a2, 0.3], 'miner');
        await cluster.mine(1);

        final engine = newEngine();
        final snap = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(snap.sync, isA<SyncUpToDate>());
        expect(snap.balance!.spendable, 130000000);
        expect(engine.lastStats.unverifiedEntries, 0);
        expect(engine.lastStats.rejectedTransactions, 0);
        await expectMatchesCore(snap);
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'live mode picks up a new block through Electrum notifications',
      () async {
        final engine = newEngine();
        await engine.start();
        final before = engine.current.balance!.spendable;
        final updated = engine.snapshots.firstWhere(
          (s) =>
              s.sync is SyncUpToDate &&
              s.balance!.spendable == before + 25000000,
        );
        await cluster.core.call('sendtoaddress', [
          await subjectAddress(),
          0.25,
        ], 'miner');
        await cluster.mine(1);
        final snap = await updated.timeout(const Duration(seconds: 30));
        await expectMatchesCore(snap);
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a spend with change (signed by Core\'s test wallet) matches Core',
      () async {
        final minerAddr =
            await cluster.core.call('getnewaddress', [], 'miner') as String;
        await cluster.core.call('sendtoaddress', [minerAddr, 0.4], 'subject');
        await cluster.mine(1);
        final engine = newEngine();
        final snap = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        await expectMatchesCore(snap);
        expect(snap.transactions.where((t) => t.netSats < 0), hasLength(1));
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'a new engine resumes from storage without refetching history',
      () async {
        final engine = newEngine();
        final snap = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(engine.lastStats.historiesFetched, 0);
        expect(engine.lastStats.transactionsFetched, 0);
        expect(engine.lastStats.merkleChecks, 0);
        await expectMatchesCore(snap);
        await engine.dispose();
      },
    );

    test(
      'florestad restart: stale while down, recovers after restart',
      () async {
        final client = newClient();
        final engine = newEngine(client: client);
        final ok = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );

        await cluster.stopFlorestad();
        final down = await engine.syncOnce();
        expect(down.isLeft(), isTrue);
        expect(engine.current.sync, isA<SyncStale>());
        expect(engine.current.balance, ok.balance, reason: 'last balance kept');

        await cluster.startFlorestad();
        final back = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(back.sync, isA<SyncUpToDate>());
        await expectMatchesCore(back);
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'a reorg removes an orphaned coinbase that florestad still serves',
      () async {
        final cbAddress = await subjectAddress();
        final cbBlock = (await cluster.mine(1, to: cbAddress)).single;
        final engine = newEngine();
        final withCb = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(withCb.balance!.immature, 5000000000);
        await expectMatchesCore(withCb);

        final cbTxid =
            ((await cluster.core.call('getblock', [cbBlock]) as Map)['tx']
                    as List)
                .first;
        await cluster.core.call('invalidateblock', [cbBlock]);
        await cluster.mine(2);
        final orphaned = [
          for (final t
              in (await cluster.core.call('listtransactions', [
                    '*',
                    1000,
                  ], 'subject'))
                  as List)
            if ((t as Map)['txid'] == cbTxid) t['category'],
        ];
        expect(orphaned, [
          'orphan',
        ], reason: 'Core marks the reorged coinbase orphan');
        final after = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(engine.lastStats.reorgDetected, isTrue);
        expect(after.balance!.immature, 0);
        expect(after.transactions.where((t) => t.txid == cbTxid), isEmpty);
        await expectMatchesCore(after);

        // Evidence for the upstream behaviour (not an assertion on it).
        final info =
            await cluster.core.call('getaddressinfo', [cbAddress], 'subject')
                as Map;
        final spk = engine.scripts.firstWhere(
          (s) => s.scriptPubKey == info['scriptPubKey'],
        );
        final probe = newClient();
        await probe.connect();
        final served = await probe.history(spk.scripthash);
        // ignore: avoid_print
        print(
          'florestad Electrum history for the orphaned coinbase script: $served',
        );
        await probe.close();
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test(
      'unconfirmed incoming payments are not counted as confirmed',
      () async {
        final engine = newEngine();
        final before = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        await cluster.core.call('sendtoaddress', [
          await subjectAddress(),
          0.2,
        ], 'miner');
        await Future<void>.delayed(const Duration(seconds: 3));
        final during = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        expect(during.balance!.confirmed, before.balance!.confirmed);
        final core = await coreBalances();
        // ignore: avoid_print
        print(
          'mempool: Core untrusted_pending=${core['untrusted_pending']}, '
          'engine pending=${during.balance!.pending} (florestad v0.9.1 exposes '
          'no mempool over Electrum)',
        );
        await cluster.mine(1);
        final mined = (await engine.syncOnce()).getOrElse(
          (f) => throw StateError('$f'),
        );
        await expectMatchesCore(mined);
        await engine.dispose();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'refuses to sync a wallet whose network differs from the server',
      () async {
        final signetAccount = WalletAccount(
          id: 'wrongnet',
          network: BitcoinNetwork.signet,
          external: account.external,
          internal: account.internal,
        );
        final engine = newEngine(acct: signetAccount);
        final r = await engine.syncOnce();
        expect(r.getLeft().toNullable(), isA<ChainMismatchFailure>());
        expect(engine.current.sync, isA<SyncBlocked>());
        expect(
          File('${storeDir.path}/wallet-wrongnet.json').existsSync(),
          isFalse,
        );
        await engine.dispose();
      },
    );
  });
}
