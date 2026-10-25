import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/wallet/data/bip32_address_deriver.dart';
import 'package:floresta_gui/features/wallet/data/script_address.dart';
import 'package:floresta_gui/features/wallet/data/wallet_sync_engine.dart';
import 'package:floresta_gui/features/wallet/data/watched_accounts.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_account.dart';
import 'package:floresta_gui/features/wallet/domain/watched_list.dart';
import 'package:floresta_gui/features/wallet/presentation/amount_format.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/wallet_fixtures.dart';

void main() {
  group('addressForScript', () {
    test('segwit v0 and v1 match BIP-173 / BIP-350 vectors', () {
      const p2wpkh = '0014751e76e8199196d454941c45d1b3a323f1433bd6';
      expect(
        addressForScript(p2wpkh, BitcoinNetwork.bitcoin),
        'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
      );
      expect(
        addressForScript(p2wpkh, BitcoinNetwork.signet),
        'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
      );
      expect(
        addressForScript(
          '512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
          BitcoinNetwork.bitcoin,
        ),
        'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0',
      );
      expect(
        addressForScript(p2wpkh, BitcoinNetwork.regtest),
        startsWith('bcrt1q'),
      );
    });

    test(
      'P2PKH matches the genesis output address; P2SH keeps its payload',
      () {
        expect(
          addressForScript(
            '76a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac',
            BitcoinNetwork.bitcoin,
          ),
          '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
        );
        const hash = 'e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a';
        final p2sh = addressForScript('a914${hash}87', BitcoinNetwork.signet)!;
        expect(p2sh, startsWith('2'));
        final decoded = Base58Decoder.checkDecode(p2sh);
        expect(decoded.first, 0xc4);
        expect(BytesUtils.toHexString(decoded.sublist(1)), hash);
      },
    );

    test('non-standard or malformed scripts give null', () {
      expect(addressForScript('6a0401020304', BitcoinNetwork.bitcoin), isNull);
      expect(addressForScript('zz', BitcoinNetwork.bitcoin), isNull);
    });
  });

  group('WatchedAccounts.fromListed', () {
    final external = vectorType('wpkh')['external']! as String;
    final internal = vectorType('wpkh')['internal']! as String;

    test('pairs receive and change branches into one account', () {
      final w = WatchedAccounts.fromListed([
        internal,
        external,
      ], BitcoinNetwork.regtest);
      expect(w.accounts, hasLength(1));
      expect(w.accounts.single.external.value, external);
      expect(w.accounts.single.internal.value, internal);
      expect(w.accounts.single.id, matches(RegExp(r'^a[0-9a-f]{16}$')));
      expect(w.receiveOnly, isEmpty);
      expect(w.unsupported, isEmpty);
    });

    test('a receive branch alone is flagged; the rest is unsupported', () {
      final w = WatchedAccounts.fromListed([
        external,
        'addr(bcrt1qexample)',
      ], BitcoinNetwork.regtest);
      expect(w.accounts, isEmpty);
      expect(w.receiveOnly, [external]);
      expect(w.unsupported, ['addr(bcrt1qexample)']);
      final changeOnly = WatchedAccounts.fromListed([
        internal,
      ], BitcoinNetwork.regtest);
      expect(changeOnly.unsupported, [internal]);
    });
  });

  group('WatchedList (WAL-07)', () {
    test('"no wallets" only after two empty answers in a row', () {
      var l = const WatchedList([]);
      l = l.next(const []);
      expect(l.checking, isTrue);
      expect(l.knownEmpty, isFalse);
      l = l.next(const []);
      expect(l.knownEmpty, isTrue);
      l = l.next(const ['d']);
      expect(l.knownEmpty, isFalse);
      expect(l.emptyAnswers, 0);
      expect(l.next(const []).checking, isTrue, reason: 'count restarts');
    });
  });

  group('formatBtc', () {
    test('integer formatting with 8 decimals and signs', () {
      expect(formatBtc(149997180), '1.49997180 BTC');
      expect(formatBtc(5000000000), '50.00000000 BTC');
      expect(formatBtc(0), '0.00000000 BTC');
      expect(formatBtc(-12000, signed: true), '−0.00012000 BTC');
      expect(formatBtc(12000, signed: true), '+0.00012000 BTC');
      expect(formatBtc(210000000000000), '2,100,000.00000000 BTC');
    });
  });

  group('AddressActivity on the Core fixture chain', () {
    test('per-address balances add up to the wallet balance', () async {
      final parsed = WatchedAccounts.fromListed([
        vectorType('wpkh')['external']! as String,
        vectorType('wpkh')['internal']! as String,
      ], BitcoinNetwork.regtest).accounts.single;
      final server = FixtureElectrumClient();
      final engine = WalletSyncEngine(
        account: parsed,
        client: server,
        chain: FixtureChainView(),
        store: MemoryWalletStore(),
        deriver: Bip32AddressDeriver(),
        coverage: 25,
        indexingGrace: Duration.zero,
      );
      server.indexFixtureChain(engine.scripts.map((s) => s.scriptPubKey));
      final snap = (await engine.syncOnce()).toNullable()!;
      final b = snap.balance!;
      expect(snap.addresses, hasLength(50));
      expect(
        snap.addresses.fold<int>(0, (sum, a) => sum + a.balanceSats),
        b.confirmed + b.pending,
      );
      final used = snap.addresses.where((a) => a.used).toList();
      expect(used, isNotEmpty);
      expect(used.every((a) => a.lastHeight != null), isTrue);
      expect(
        snap.addresses.first.keychain,
        Keychain.external,
        reason: 'receive branch first',
      );
      await engine.dispose();
    });
  });
}
