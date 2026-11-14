import 'bitcoin_network.dart';

/// Where compact block filters (and so wallet history searches) start.
///
/// florestad v0.9.1 downloads filters from block 1 unless
/// `--filters-start-height` is given (`running_ctx.rs:491`), which is about
/// 11 GB on mainnet (13+ GB has been reported). It applies the start height
/// only while its filter store is empty, so moving the birthday earlier
/// later does not fetch older filters.
abstract final class WalletBirthday {
  static const firstYear = 2009;

  /// Blocks subtracted from a year's first block so the search always starts
  /// a little before the chosen year (about one week).
  static const safetyMargin = 1000;

  /// Approximate mainnet height at 1 January of each year, at or slightly
  /// before the year's first block. Values from Mandacaru
  /// (`presentation/utils/WalletBirthday.kt`, MIT, © João Victor Sena), not
  /// re-derived here; [safetyMargin] covers small errors.
  static const _mainnetJan1 = <int, int>{
    2009: 1,
    2010: 32256,
    2011: 100388,
    2012: 160255,
    2013: 214935,
    2014: 278287,
    2015: 336860,
    2016: 391182,
    2017: 446033,
    2018: 501950,
    2019: 556445,
    2020: 610682,
    2021: 663913,
    2022: 717050,
    2023: 769800,
    2024: 822375,
    2025: 877130,
    2026: 929690,
  };

  static int get lastKnownYear =>
      _mainnetJan1.keys.reduce((a, b) => a > b ? a : b);

  /// Years the user can pick (mainnet only).
  static List<int> get selectableYears => [
    for (var y = lastKnownYear; y >= firstYear; y--) y,
  ];

  /// Filter start height for a wallet first used in [year] (mainnet).
  static int mainnetHeightForYear(int year) {
    final h = _mainnetJan1[year.clamp(firstYear, lastKnownYear)]!;
    return h - safetyMargin < 1 ? 1 : h - safetyMargin;
  }

  /// The height passed as `--filters-start-height`, or null to let
  /// florestad start from block 1.
  ///
  /// Without a birthday, filters start at the network's built-in Utreexo
  /// snapshot height (recent history only, small on disk); networks without
  /// a snapshot (testnet4, regtest) are small enough to keep everything.
  static int? filtersStartHeight(BitcoinNetwork network, int? birthdayYear) {
    if (network.isMainnet && birthdayYear != null) {
      return mainnetHeightForYear(birthdayYear);
    }
    final snapshot = network.assumeUtreexoHeight;
    return snapshot > 0 ? snapshot : null;
  }
}
