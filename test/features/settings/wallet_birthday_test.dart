import 'package:floresta_desktop/features/node/data/florestad_launch_args.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:floresta_desktop/features/settings/domain/wallet_birthday.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a birthday year starts filters a little before that year', () {
    expect(
      WalletBirthday.mainnetHeightForYear(2024),
      822375 - WalletBirthday.safetyMargin,
    );
    expect(WalletBirthday.mainnetHeightForYear(2009), 1);
    expect(
      WalletBirthday.mainnetHeightForYear(2099),
      WalletBirthday.mainnetHeightForYear(WalletBirthday.lastKnownYear),
    );
  });

  test('without a birthday, filters start at the built-in snapshot', () {
    expect(
      WalletBirthday.filtersStartHeight(BitcoinNetwork.bitcoin, null),
      939969,
    );
    expect(
      WalletBirthday.filtersStartHeight(BitcoinNetwork.signet, null),
      296870,
    );
    expect(
      WalletBirthday.filtersStartHeight(BitcoinNetwork.regtest, null),
      isNull,
    );
  });

  test('launch args pass --filters-start-height only with filters on', () {
    const withYear = NodeSettings(walletBirthdayYear: 2024);
    expect(
      florestadLaunchArgs(withYear),
      containsAllInOrder([
        '--filters-start-height',
        '${822375 - WalletBirthday.safetyMargin}',
      ]),
    );
    const off = NodeSettings(
      walletBirthdayYear: 2024,
      disableCompactFilters: true,
    );
    expect(florestadLaunchArgs(off), isNot(contains('--filters-start-height')));
  });

  test('an out-of-range birthday is rejected', () {
    expect(
      const NodeSettings(walletBirthdayYear: 1999).validate().isLeft(),
      isTrue,
    );
  });
}
