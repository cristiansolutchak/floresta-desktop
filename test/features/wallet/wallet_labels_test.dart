import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/wallet/data/wallet_label_store.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_labels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_process.dart' show FakeKeys;

void main() {
  group('WalletName.parse', () {
    test('trims and collapses spaces', () {
      expect(
        WalletName.parse('  Cold   storage ').toNullable(),
        'Cold storage',
      );
    });

    test('refuses empty and long names', () {
      expect(WalletName.parse('   ').isLeft(), isTrue);
      expect(WalletName.parse('a' * 40).isRight(), isTrue);
      expect(WalletName.parse('a' * 41).isLeft(), isTrue);
    });

    test('refuses private keys and seed phrases as secrets', () {
      for (final secret in [
        FakeKeys.xprv,
        FakeKeys.wifCompressed,
        'abandon ability able about above absent absorb abstract absurd '
            'abuse access accident',
      ]) {
        expect(
          WalletName.parse(secret).getLeft().toNullable(),
          isA<SecretMaterialRejectedFailure>(),
          reason: secret,
        );
      }
    });

    test('refuses public keys, key fragments and descriptors', () {
      for (final keyish in [
        FakeKeys.xpub,
        'my ${FakeKeys.tpub}',
        // What a 40-character field would have kept of a pasted key: no
        // longer a whole key, still refused (it used to be truncated first).
        FakeKeys.xprv.substring(0, 40),
        FakeKeys.zpub.substring(0, 20),
        'wpkh(abc)',
      ]) {
        expect(WalletName.parse(keyish).isLeft(), isTrue, reason: keyish);
      }
      // Ordinary names that merely contain "pub" are fine.
      expect(WalletName.parse('Pub savings').isRight(), isTrue);
      expect(WalletName.parse('xpub wallet').isRight(), isTrue);
    });
  });

  group('WalletLabelStore', () {
    test('round-trips names and removals by account id', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = WalletLabelStore(prefs);
      await store.write({
        'a0123': const WalletLabel(name: 'Savings'),
        'a4567': const WalletLabel(name: 'Old', hidden: true),
        'a89ab': const WalletLabel(), // nothing to keep
      });
      expect(store.read(), {
        'a0123': const WalletLabel(name: 'Savings'),
        'a4567': const WalletLabel(name: 'Old', hidden: true),
      });
      expect(prefs.getString(WalletLabelStore.key), isNot(contains('a89ab')));
    });

    test('a damaged entry reads as no labels, never a crash', () async {
      SharedPreferences.setMockInitialValues({WalletLabelStore.key: '{nope'});
      final prefs = await SharedPreferences.getInstance();
      expect(WalletLabelStore(prefs).read(), isEmpty);
    });
  });
}
