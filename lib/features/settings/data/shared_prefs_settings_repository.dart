import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/failure.dart';
import '../domain/bitcoin_network.dart';
import '../domain/node_settings.dart';
import '../domain/settings_repository.dart';

class SharedPrefsSettingsRepository implements SettingsRepository {
  SharedPrefsSettingsRepository(
    this._prefs, {
    this.defaultNetwork = BitcoinNetwork.bitcoin,
  });

  /// Used until the user picks a network (depends on the build flavour).
  final BitcoinNetwork defaultNetwork;

  final SharedPreferences _prefs;

  static const _kOnboarding = 'settings.onboardingComplete';
  static const _kExecutable = 'settings.executablePath';
  static const _kNetwork = 'settings.network';
  static const _kDataDir = 'settings.dataDir';
  static const _kRpcPort = 'settings.rpcPort';
  static const _kLogToFile = 'settings.logToFile';
  static const _kNoCfilters = 'settings.disableCompactFilters';
  static const _kBirthday = 'settings.walletBirthdayYear';
  static const _kAssumeUtreexo = 'settings.assumeUtreexo';
  static const _kBackfill = 'settings.backfill';
  static const _kExistingNode = 'settings.useExistingNode';
  static const _kSwiftSync = 'settings.swiftSync';
  static const _kHintsOrigin = 'settings.hintsOrigin';

  @override
  NodeSettings load() {
    final defaults = NodeSettings(network: defaultNetwork);
    final onboarded = _prefs.getBool(_kOnboarding) ?? false;
    final stored = NodeSettings(
      onboardingComplete: onboarded,
      executablePath: _prefs.getString(_kExecutable),
      network:
          BitcoinNetwork.fromCliValue(_prefs.getString(_kNetwork) ?? '') ??
          defaults.network,
      dataDir: _prefs.getString(_kDataDir),
      rpcPort: _prefs.getInt(_kRpcPort),
      logToFile: _prefs.getBool(_kLogToFile) ?? defaults.logToFile,
      disableCompactFilters:
          _prefs.getBool(_kNoCfilters) ?? defaults.disableCompactFilters,
      walletBirthdayYear: _prefs.getInt(_kBirthday),
      backfill: _prefs.getBool(_kBackfill) ?? defaults.backfill,
      useExistingNode: _prefs.getBool(_kExistingNode) ?? false,
      // A node set up before Swift Sync existed keeps the method it was
      // started with: its data folder could not use Swift Sync anyway.
      swiftSync: _prefs.getBool(_kSwiftSync) ?? !onboarded,
      // Stored before ADR-0011 meant the old default, Fast Start.
      assumeUtreexo:
          _prefs.getBool(_kAssumeUtreexo) ??
          (onboarded ? true : defaults.assumeUtreexo),
      hintsOrigin: _prefs.getString(_kHintsOrigin) ?? defaults.hintsOrigin,
    );
    // Values edited outside the app could be invalid. Keep the onboarding flag,
    // network and sync method but drop the paths/port/origin so the node is never launched
    // with arguments the user did not validate.
    return stored.validate().getOrElse(
      (_) => NodeSettings(
        onboardingComplete: stored.onboardingComplete,
        network: stored.network,
        // The sync method is tied to the data folder; never switch it here.
        swiftSync: stored.swiftSync,
        assumeUtreexo: stored.assumeUtreexo,
        backfill: stored.backfill,
      ),
    );
  }

  @override
  Future<Either<Failure, Unit>> save(NodeSettings settings) async {
    final validated = settings.validate();
    if (validated case Left(:final value)) return Left(value);
    try {
      await _prefs.setBool(_kOnboarding, settings.onboardingComplete);
      await _setOrRemove(_kExecutable, settings.executablePath);
      await _prefs.setString(_kNetwork, settings.network.cliValue);
      await _setOrRemove(_kDataDir, settings.dataDir);
      final port = settings.rpcPort;
      port == null
          ? await _prefs.remove(_kRpcPort)
          : await _prefs.setInt(_kRpcPort, port);
      await _prefs.setBool(_kLogToFile, settings.logToFile);
      await _prefs.setBool(_kNoCfilters, settings.disableCompactFilters);
      await _prefs.setBool(_kAssumeUtreexo, settings.assumeUtreexo);
      await _prefs.setBool(_kBackfill, settings.backfill);
      await _prefs.setBool(_kExistingNode, settings.useExistingNode);
      await _prefs.setBool(_kSwiftSync, settings.swiftSync);
      await _prefs.setString(_kHintsOrigin, settings.hintsOrigin);
      final year = settings.walletBirthdayYear;
      year == null
          ? await _prefs.remove(_kBirthday)
          : await _prefs.setInt(_kBirthday, year);
      return const Right(unit);
    } on Exception catch (e) {
      return Left(StorageFailure('$e'));
    }
  }

  Future<void> _setOrRemove(String key, String? value) async {
    value == null
        ? await _prefs.remove(key)
        : await _prefs.setString(key, value);
  }
}
