import 'dart:async';
import 'dart:io';

import 'package:floresta_desktop/core/electrum/electrum_client.dart';
import 'package:floresta_desktop/core/errors/failure.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/wallet/data/bip32_address_deriver.dart';
import 'package:floresta_desktop/features/wallet/data/descriptor_checksum.dart';
import 'package:floresta_desktop/features/wallet/data/json_file_wallet_store.dart';
import 'package:floresta_desktop/features/wallet/data/single_sig_descriptor_parser.dart';
import 'package:floresta_desktop/features/wallet/data/transaction_verification.dart';
import 'package:floresta_desktop/features/wallet/data/wallet_sync_engine.dart';
import 'package:floresta_desktop/features/wallet/domain/balance_calculator.dart';
import 'package:floresta_desktop/features/wallet/domain/wallet_account.dart';
import 'package:floresta_desktop/features/wallet/domain/wallet_state.dart';
import 'package:floresta_desktop/features/wallet/domain/wallet_sync_ports.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_process.dart';
import '../../helpers/wallet_fixtures.dart';

const _parser = SingleSigDescriptorParser();

WalletAccount _account([String kind = 'wpkh']) {
  final parsed = _parser
      .parseAccount(
        vectorType(kind)['multipath']! as String,
        BitcoinNetwork.regtest,
      )
      .getOrElse((f) => throw StateError(f.message));
  return WalletAccount(
    id: 'acct1',
    network: BitcoinNetwork.regtest,
    external: parsed.external,
    internal: parsed.internal,
  );
}

void main() {
  group('DescriptorChecksum (BIP-380)', () {
    test('matches Bitcoin Core for every fixture descriptor', () {
      for (final kind in ['pkh', 'sh_wpkh', 'wpkh', 'tr']) {
        final t = vectorType(kind);
        for (final d in [t['external'], t['internal'], t['multipath']]) {
          final s = d! as String;
          final i = s.indexOf('#');
          expect(
            DescriptorChecksum.compute(s.substring(0, i)),
            s.substring(i + 1),
            reason: s,
          );
        }
      }
      final mainnet =
          (walletVectors['mainnet_wpkh']! as Map)['external'] as String;
      final i = mainnet.indexOf('#');
      expect(
        DescriptorChecksum.compute(mainnet.substring(0, i)),
        mainnet.substring(i + 1),
      );
    });

    test('rejects characters outside the descriptor charset', () {
      expect(DescriptorChecksum.compute('wpkh(é)'), isNull);
    });
  });

  group('SingleSigDescriptorParser', () {
    test('splits multipath into Core-identical single-branch descriptors', () {
      for (final kind in ['pkh', 'sh_wpkh', 'wpkh', 'tr']) {
        final t = vectorType(kind);
        final r = _parser
            .parseAccount(t['multipath']! as String, BitcoinNetwork.regtest)
            .getOrElse((f) => throw StateError(f.message));
        expect(r.external.value, t['external'], reason: kind);
        expect(r.internal.value, t['internal'], reason: kind);
      }
    });

    test('derives the internal branch from a /0/* descriptor', () {
      final t = vectorType('wpkh');
      final r = _parser
          .parseAccount(
            (t['external']! as String).split('#').first,
            BitcoinNetwork.regtest,
          )
          .toNullable()!;
      expect(r.internal.value, t['internal']);
    });

    test(
      'accepts mainnet keys only on mainnet, test keys only off mainnet',
      () {
        final mainnet =
            (walletVectors['mainnet_wpkh']! as Map)['external'] as String;
        expect(
          _parser.parseAccount(mainnet, BitcoinNetwork.bitcoin).isRight(),
          isTrue,
        );
        final onRegtest = _parser.parseAccount(mainnet, BitcoinNetwork.regtest);
        expect(
          onRegtest.getLeft().toNullable()?.message,
          contains('mainnet key'),
        );
        final testKey = vectorType('wpkh')['multipath']! as String;
        expect(
          _parser.parseAccount(testKey, BitcoinNetwork.bitcoin).isLeft(),
          isTrue,
        );
      },
    );

    test('rejects what florestad v0.9.1 mishandles or cannot watch', () {
      final body = (vectorType('wpkh')['external']! as String).split('#').first;
      final cases = {
        'wrong checksum': '$body#qqqqqqqq',
        'hardened wildcard': body.replaceFirst('/0/*)', '/0/*h)'),
        'hardened step after key': body.replaceFirst('/0/*)', "/0'/0/*)"),
        'change-only': body.replaceFirst('/0/*)', '/1/*)'),
        'addr()': 'addr(bcrt1qgncurv8kddwk6skpxe4rxmmd3kc5n86s757cer)',
        'multisig': 'wsh(multi(1,$body))',
        'garbage': 'wpkh(garbage)',
        'corrupted key': body.replaceFirst('tpub', 'tpuc'),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
          _parser.parseAccount(value, BitcoinNetwork.regtest).isLeft(),
          isTrue,
          reason: key,
        );
      }
    });

    test('rejects private key material before parsing', () {
      final r = _parser.parseAccount(
        'wpkh(${FakeKeys.tprv}/0/*)',
        BitcoinNetwork.regtest,
      );
      expect(r.getLeft().toNullable(), isA<SecretMaterialRejectedFailure>());
    });
  });

  group('Bip32AddressDeriver', () {
    test('reproduces Bitcoin Core scripts (4 types x 2 branches x 25)', () {
      final deriver = Bip32AddressDeriver();
      for (final kind in ['pkh', 'sh_wpkh', 'wpkh', 'tr']) {
        final account = _account(kind);
        final scripts = vectorType(kind)['scripts']! as Map;
        for (final k in Keychain.values) {
          final expected = (scripts[k.name] as List).cast<String>();
          for (var i = 0; i < expected.length; i++) {
            expect(
              deriver.derive(account.descriptor(k), i).scriptPubKey,
              expected[i],
              reason: '$kind ${k.name} $i',
            );
          }
        }
      }
    });

    test('derives mainnet keys identically to Core on mainnet', () {
      final v = walletVectors['mainnet_wpkh']! as Map;
      final parsed = _parser
          .parseAccount(v['external'] as String, BitcoinNetwork.bitcoin)
          .toNullable()!;
      final expected = (v['scripts'] as List).cast<String>();
      for (var i = 0; i < expected.length; i++) {
        expect(
          Bip32AddressDeriver().derive(parsed.external, i).scriptPubKey,
          expected[i],
        );
      }
    });

    test('computes the Electrum scripthash', () {
      // Value observed from florestad's Electrum server (signet validation).
      expect(
        electrumScripthash('00143552f0072385357986464c4bf6df19dafb7b3bd4'),
        'd8f9577c3e9acab81484814bbb03448481d2a5e231c3220386b99512f4fab48e',
      );
    });
  });

  group('TransactionVerification', () {
    test('parses Core transactions and recomputes their txids', () {
      for (final t in chainTxs) {
        final tx = TransactionVerification.parse(
          t['txid']! as String,
          t['raw']! as String,
        );
        expect(tx, isNotNull);
        expect(tx!.txid, t['txid']);
      }
      final roles = chainVectors['roles']! as Map;
      final cb = chainTxs.firstWhere((t) => t['txid'] == roles['coinbase']);
      expect(
        TransactionVerification.parse(
          cb['txid']! as String,
          cb['raw']! as String,
        )!.isCoinbase,
        isTrue,
      );
    });

    test('rejects raw bytes that do not hash to the claimed txid', () {
      final t = chainTxs.first;
      final raw = t['raw']! as String;
      // The version field is committed by the txid; changing it must fail.
      final tampered = raw.replaceRange(
        0,
        2,
        raw.startsWith('03') ? '04' : '03',
      );
      expect(
        TransactionVerification.parse(t['txid']! as String, tampered),
        isNull,
      );
      expect(TransactionVerification.parse('00' * 32, raw), isNull);
      expect(TransactionVerification.parse(t['txid']! as String, 'zz'), isNull);
    });

    test('witness bytes are not committed by the txid (segwit)', () {
      // Altering witness data changes the wtxid, not the txid, and leaves
      // inputs, outputs and amounts untouched, so accounting is unaffected.
      final t = chainTxs.firstWhere(
        (t) => (t['raw']! as String).substring(8, 12) == '0001',
      );
      final raw = t['raw']! as String;
      final witnessTampered = raw.replaceRange(
        raw.length - 10,
        raw.length - 8,
        '01',
      );
      expect(
        TransactionVerification.parse(
          t['txid']! as String,
          witnessTampered,
        )?.txid,
        t['txid'],
      );
    });

    test('verifies merkle proofs and header hashes against Core', () {
      for (final t in chainTxs) {
        final m = t['merkle']! as Map;
        final proof = MerkleProof(
          blockHeight: m['block_height'] as int,
          position: m['pos'] as int,
          siblings: (m['siblings'] as List).cast<String>(),
        );
        expect(
          TransactionVerification.headerHash(t['header']! as String),
          t['block_hash'],
        );
        expect(
          TransactionVerification.merkleMatches(
            txid: t['txid']! as String,
            proof: proof,
            headerHex: t['header']! as String,
          ),
          isTrue,
        );
        final wrongPos = MerkleProof(
          blockHeight: proof.blockHeight,
          position: proof.position ^ 1,
          siblings: proof.siblings,
        );
        if (proof.siblings.isNotEmpty) {
          expect(
            TransactionVerification.merkleMatches(
              txid: t['txid']! as String,
              proof: wrongPos,
              headerHex: t['header']! as String,
            ),
            isFalse,
          );
        }
      }
    });

    test('computes Electrum status hashes', () {
      expect(TransactionVerification.electrumStatus(const []), isNull);
      // Reference values from Python hashlib.sha256.
      expect(
        TransactionVerification.electrumStatus(const [HistoryEntry('ab', 3)]),
        '583dc9bc18720f7d8a233b83936675fdb786898206bb207b2b678e730845ea4d',
      );
      expect(
        TransactionVerification.electrumStatus(const [
          HistoryEntry('ab', 3),
          HistoryEntry('cd', 0),
        ]),
        'fb1ab69af8423714cd9e9c7bcb6aa1898067b5c62ad6a44282d93364ce6a52a8',
      );
    });
  });

  group('BalanceCalculator', () {
    ParsedTransaction tx(
      String id, {
      List<OutPoint> ins = const [],
      List<TxOutput> outs = const [],
      bool cb = false,
    }) =>
        ParsedTransaction(txid: id, inputs: ins, outputs: outs, isCoinbase: cb);
    const own = {'aa', 'bb'};

    test('receive, spend with change, and fees', () {
      final r = BalanceCalculator.compute(
        ownScripts: own,
        tipHeight: 200,
        records: [
          WalletTxRecord(
            tx('f', outs: [const TxOutput(0, 200000000, 'aa')]),
            const Confirmed(150, 'h'),
          ),
          WalletTxRecord(
            tx(
              's',
              ins: [const OutPoint('f', 0)],
              outs: [
                const TxOutput(0, 50000000, 'zz'),
                const TxOutput(1, 149997180, 'bb'),
              ],
            ),
            const Confirmed(151, 'h'),
          ),
        ],
      );
      expect(r.balance.confirmed, 149997180);
      expect(r.balance.spendable, 149997180);
      expect(r.balance.pending, 0);
      expect(r.history.map((h) => h.netSats), [-50002820, 200000000]);
    });

    test('coinbase is immature for 100 blocks', () {
      WalletBalance at(int tip) => BalanceCalculator.compute(
        ownScripts: own,
        tipHeight: tip,
        records: [
          WalletTxRecord(
            tx('c', outs: [const TxOutput(0, 5000000000, 'aa')], cb: true),
            const Confirmed(100, 'h'),
          ),
        ],
      ).balance;
      expect(at(100).immature, 5000000000);
      expect(at(100).spendable, 0);
      expect(at(198).immature, 5000000000);
      expect(at(199).immature, 0);
      expect(at(199).spendable, 5000000000);
    });

    test('unverified entries never count; pending ones are separate', () {
      final r = BalanceCalculator.compute(
        ownScripts: own,
        tipHeight: 10,
        records: [
          WalletTxRecord(
            tx('orphan', outs: [const TxOutput(0, 7, 'aa')]),
            const Unverified('reorg'),
          ),
          WalletTxRecord(
            tx('p', outs: [const TxOutput(0, 9, 'aa')]),
            const PendingValidation(11),
          ),
        ],
      );
      expect(r.balance.confirmed, 0);
      expect(r.balance.pending, 9);
      expect(r.history.map((h) => h.txid), ['p']);
    });

    test('a pending spend of a confirmed coin is negative pending', () {
      final r = BalanceCalculator.compute(
        ownScripts: own,
        tipHeight: 10,
        records: [
          WalletTxRecord(
            tx('f', outs: [const TxOutput(0, 100, 'aa')]),
            const Confirmed(5, 'h'),
          ),
          WalletTxRecord(
            tx(
              's',
              ins: [const OutPoint('f', 0)],
              outs: [const TxOutput(0, 90, 'zz')],
            ),
            const Unconfirmed(),
          ),
        ],
      );
      expect(r.balance.confirmed, 100);
      expect(r.balance.spendable, 0);
      expect(r.balance.pending, -100);
      expect(r.balance.total, 0);
    });
  });

  group('JsonFileWalletStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wallet_store_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round-trips state and leaves no temp file', () async {
      final store = JsonFileWalletStore(dir);
      const data = WalletSyncData(
        statuses: {'sh1': 'st', 'sh2': null},
        histories: {
          'sh1': ['t1'],
        },
        transactions: {
          't1': StoredTx(rawHex: 'ab', height: 5, verifiedBlockHash: 'h5'),
        },
        tip: (height: 5, hash: 'h5'),
      );
      expect((await store.save('acct1', data)).isRight(), isTrue);
      expect((await JsonFileWalletStore(dir).load('acct1')).toNullable(), data);
      expect(
        dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('missing file is empty state; corrupt file is a failure', () async {
      final store = JsonFileWalletStore(dir);
      expect((await store.load('none')).toNullable(), const WalletSyncData());
      File('${dir.path}/wallet-bad.json').writeAsStringSync('{truncated');
      expect(
        (await store.load('bad')).getLeft().toNullable(),
        isA<StorageFailure>(),
      );
    });

    test('rejects unsafe account ids', () async {
      expect((await JsonFileWalletStore(dir).load('../x')).isLeft(), isTrue);
    });
  });

  group('WalletSyncEngine', () {
    late WalletAccount account;
    late FixtureElectrumClient server;
    late FixtureChainView chain;
    late MemoryWalletStore store;

    WalletSyncEngine engine() => WalletSyncEngine(
      account: account,
      client: server,
      chain: chain,
      store: store,
      deriver: Bip32AddressDeriver(),
      coverage: 25,
      indexingGrace: Duration.zero,
    );

    setUp(() {
      account = _account();
      server = FixtureElectrumClient();
      chain = FixtureChainView();
      store = MemoryWalletStore();
      final e = engine();
      server.indexFixtureChain(e.scripts.map((s) => s.scriptPubKey));
    });

    test('matches Bitcoin Core balances for the same keys', () async {
      final snap = (await engine().syncOnce()).getOrElse(
        (f) => throw StateError(f.message),
      );
      final expected = chainVectors['expected_balances']! as Map;
      expect(snap.balance!.spendable, btcToSats(expected['trusted'] as num));
      expect(snap.balance!.immature, btcToSats(expected['immature'] as num));
      expect(snap.transactions, hasLength(3));
      expect(
        snap.transactions.every((t) => t.confirmation is Confirmed),
        isTrue,
      );
      expect(snap.sync, isA<SyncUpToDate>());
    });

    test('resumes from storage without refetching unchanged scripts', () async {
      await engine().syncOnce();
      final second = engine();
      final before = server.calls.length;
      final snap = (await second.syncOnce()).toNullable()!;
      final newCalls = server.calls.sublist(before);
      expect(newCalls.where((c) => c == 'get_history'), isEmpty);
      expect(newCalls.where((c) => c == 'transaction.get'), isEmpty);
      expect(newCalls.where((c) => c == 'get_merkle'), isEmpty);
      expect(second.lastStats.historiesFetched, 0);
      expect(snap.balance, isNotNull);
    });

    test(
      'duplicate notifications and repeated passes are idempotent',
      () async {
        final e = engine();
        final first = (await e.syncOnce()).toNullable()!;
        final again = await Future.wait([
          e.syncOnce(),
          e.syncOnce(),
          e.syncOnce(),
        ]);
        for (final r in again) {
          expect(r.toNullable()!.balance, first.balance);
          expect(
            r.toNullable()!.transactions.length,
            first.transactions.length,
          );
        }
      },
    );

    test(
      'drops a transaction orphaned by a reorg that the server still lists',
      () async {
        final e = engine();
        final before = (await e.syncOnce()).toNullable()!;
        expect(before.balance!.immature, greaterThan(0));
        // Reorg: block 104 (the coinbase block) replaced; server keeps old data.
        final roles = chainVectors['roles']! as Map;
        final cbHeight =
            chainTxs.firstWhere(
                  (t) => t['txid'] == roles['coinbase'],
                )['height']!
                as int;
        chain.hashes[cbHeight] = 'ff' * 32;
        final after = (await e.syncOnce()).toNullable()!;
        expect(e.lastStats.reorgDetected, isTrue);
        expect(after.balance!.immature, 0);
        expect(
          after.transactions.where((t) => t.txid == roles['coinbase']),
          isEmpty,
        );
      },
    );

    test('treats entries above the validated height as pending', () async {
      chain.validatedOverride = 103;
      final snap = (await engine().syncOnce()).toNullable()!;
      expect(snap.balance!.immature, 0);
      expect(snap.balance!.pending, btcToSats(50));
      expect(snap.transactions.first.confirmation, isA<PendingValidation>());
    });

    test('rejects tampered transactions from the server', () async {
      final roles = chainVectors['roles']! as Map;
      final fund = roles['fund']! as String;
      final raw = server.raws[fund]!;
      // Version byte: committed by the txid.
      server.raws[fund] = raw.replaceRange(
        0,
        2,
        raw.startsWith('03') ? '04' : '03',
      );
      final e = engine();
      final snap = (await e.syncOnce()).toNullable()!;
      expect(e.lastStats.rejectedTransactions, greaterThan(0));
      expect(snap.transactions.where((t) => t.txid == fund), isEmpty);
    });

    test(
      'marks entries unverified when the merkle proof does not match',
      () async {
        final roles = chainVectors['roles']! as Map;
        final spend = roles['spend']! as String;
        final m = server.merkles[spend]!;
        server.merkles[spend] = MerkleProof(
          blockHeight: m.blockHeight,
          position: m.position,
          siblings: ['00' * 32],
        );
        final e = engine();
        final snap = (await e.syncOnce()).toNullable()!;
        expect(e.lastStats.unverifiedEntries, 1);
        expect(snap.transactions.where((t) => t.txid == spend), isEmpty);
      },
    );

    test('refuses to sync against a server on another chain', () async {
      server.genesisHash = BitcoinNetwork.signet.genesisHash;
      final e = engine();
      final r = await e.syncOnce();
      expect(r.getLeft().toNullable(), isA<ChainMismatchFailure>());
      expect(e.current.sync, isA<SyncBlocked>());
      expect(store.saves, 0);
    });

    test(
      'keeps the last balance and reports stale when the server drops',
      () async {
        final e = engine();
        final ok = (await e.syncOnce()).toNullable()!;
        server.drop();
        server.failNextConnect = true;
        final r = await e.syncOnce();
        expect(r.getLeft().toNullable(), isA<ElectrumUnavailableFailure>());
        expect(e.current.balance, ok.balance);
        expect(e.current.sync, isA<SyncStale>());
        // Reconnect succeeds on the next pass.
        expect((await e.syncOnce()).isRight(), isTrue);
        expect(e.current.sync, isA<SyncUpToDate>());
      },
    );

    test('reports stale when the node RPC is unreachable', () async {
      chain.unreachable = true;
      final e = engine();
      expect(
        (await e.syncOnce()).getLeft().toNullable(),
        isA<RpcUnreachableFailure>(),
      );
      expect(e.current.sync, isA<SyncStale>());
    });

    test('waits for the server to announce a newly validated block', () async {
      // florestad v0.9.1 indexes a block only after 1 s without client
      // traffic, and announces it right before indexing (headers.subscribe).
      final e = WalletSyncEngine(
        account: account,
        client: server,
        chain: chain,
        store: store,
        deriver: Bip32AddressDeriver(),
        coverage: 25,
        indexingGrace: const Duration(seconds: 5),
      );
      var callsBeforeAnnouncement = -1;
      Timer(const Duration(milliseconds: 300), () {
        callsBeforeAnnouncement = server.calls.length;
        server.notify(
          NewHeader(HeaderTip(chain.tip, server.headers[chain.tip]!)),
        );
      });
      final r = await e.syncOnce();
      expect(r.isRight(), isTrue);
      // No Electrum traffic at all before the announcement.
      expect(callsBeforeAnnouncement, 0);
      expect(server.calls.first, 'connect');
      expect(e.lastStats.indexingWait, lessThan(const Duration(seconds: 5)));
      // Already announced: no further waiting for the same height.
      final again = Stopwatch()..start();
      await e.syncOnce();
      expect(again.elapsed, lessThan(const Duration(seconds: 1)));
      await e.dispose();
    });

    test('falls back to the grace period when no announcement comes', () async {
      final e = WalletSyncEngine(
        account: account,
        client: server,
        chain: chain,
        store: store,
        deriver: Bip32AddressDeriver(),
        coverage: 25,
        indexingGrace: const Duration(milliseconds: 200),
      );
      final r = await e.syncOnce();
      expect(r.isRight(), isTrue);
      expect(
        e.lastStats.indexingWait,
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
      await e.dispose();
    });

    test('live mode resyncs on a status notification', () async {
      final e = engine();
      final updates = <WalletSnapshot>[];
      final sub = e.snapshots.listen(updates.add);
      await e.start();
      final count = updates.length;
      server.notify(ScriptStatusChanged(e.scripts.first.scripthash, 'x'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(updates.length, greaterThan(count));
      await sub.cancel();
      await e.dispose();
    });
  });
}
