import 'package:floresta_gui/core/build_flavor.dart';
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/node/domain/swift_sync.dart';
import 'package:floresta_gui/features/settings/data/shared_prefs_settings_repository.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('BitcoinNetwork', () {
    test('mirrors upstream default ports and subdirectories', () {
      expect(BitcoinNetwork.bitcoin.rpcPort, 8332);
      expect(BitcoinNetwork.signet.rpcPort, 38332);
      expect(BitcoinNetwork.testnet4.rpcPort, 48332);
      expect(BitcoinNetwork.regtest.rpcPort, 18442);
      expect(BitcoinNetwork.bitcoin.electrumPort, 50001);
      expect(BitcoinNetwork.signet.electrumPort, 60001);
      expect(BitcoinNetwork.bitcoin.dataSubdir, isNull);
      expect(BitcoinNetwork.signet.dataSubdir, 'signet');
    });

    test('parses CLI values', () {
      expect(BitcoinNetwork.fromCliValue('testnet4'), BitcoinNetwork.testnet4);
      expect(BitcoinNetwork.fromCliValue('mainnet'), isNull);
    });
  });

  group('NodeSettings', () {
    test('defaults to mainnet in production builds (owner decision 3)', () {
      expect(const NodeSettings().network, BitcoinNetwork.bitcoin);
      expect(BuildFlavor.production.defaultNetwork, BitcoinNetwork.bitcoin);
    });

    test('development builds default to signet', () {
      expect(BuildFlavor.development.defaultNetwork, BitcoinNetwork.signet);
      expect(BuildFlavor.compiled, BuildFlavor.production);
    });

    test('computes the data directory like upstream datadir_path', () {
      const s = NodeSettings(network: BitcoinNetwork.signet);
      expect(
        s.effectiveDataDir(homeDir: '/Users/a'),
        '/Users/a/.floresta/signet',
      );
      expect(
        const NodeSettings(
          network: BitcoinNetwork.bitcoin,
        ).effectiveDataDir(homeDir: '/Users/a'),
        '/Users/a/.floresta',
      );
      expect(
        const NodeSettings(
          dataDir: '/data/f',
          network: BitcoinNetwork.regtest,
        ).effectiveDataDir(homeDir: '/Users/a'),
        '/data/f/regtest',
      );
    });

    test('uses the network default RPC port unless overridden', () {
      expect(
        const NodeSettings().rpcEndpoint,
        Uri.parse('http://127.0.0.1:8332/'),
      );
      expect(const NodeSettings(rpcPort: 40000).effectiveRpcPort, 40000);
    });

    test('rejects invalid ports and relative paths', () {
      expect(
        const NodeSettings(rpcPort: 80).validate().getLeft().toNullable(),
        isA<ValidationFailure>(),
      );
      expect(
        const NodeSettings(dataDir: 'relative/dir').validate().isLeft(),
        isTrue,
      );
      expect(
        const NodeSettings(executablePath: 'florestad').validate().isLeft(),
        isTrue,
      );
      expect(
        const NodeSettings(dataDir: r'C:\floresta').validate().isRight(),
        isTrue,
      );
    });

    test('copyWith can clear optional values', () {
      const s = NodeSettings(dataDir: '/d', rpcPort: 40000);
      final cleared = s.copyWith(dataDir: const None(), rpcPort: const None());
      expect(cleared.dataDir, isNull);
      expect(cleared.rpcPort, isNull);
      expect(s.copyWith().dataDir, '/d');
    });
  });

  group('SharedPrefsSettingsRepository', () {
    Future<SharedPrefsSettingsRepository> repo([
      Map<String, Object> initial = const {},
    ]) async {
      SharedPreferences.setMockInitialValues(initial);
      return SharedPrefsSettingsRepository(
        await SharedPreferences.getInstance(),
      );
    }

    test('round-trips settings', () async {
      final r = await repo();
      const s = NodeSettings(
        onboardingComplete: true,
        executablePath: '/bin/florestad',
        network: BitcoinNetwork.regtest,
        dataDir: '/data',
        rpcPort: 19000,
        logToFile: false,
        disableCompactFilters: true,
      );
      expect(await r.save(s), const Right(unit));
      expect(r.load(), s);
    });

    test('a new install defaults to Swift Sync (ADR-0011)', () async {
      final s = (await repo()).load();
      expect(s.syncMethod, SyncMethod.swiftSync);
      expect(s.assumeUtreexo, isFalse);
      expect(s.hintsOrigin, defaultHintsOrigin);
    });

    test('a node set up before Swift Sync keeps Fast Start', () async {
      // Stored before ADR-0011: onboarding done, no sync keys at all.
      final s = (await repo({'settings.onboardingComplete': true})).load();
      expect(s.syncMethod, SyncMethod.fastStart);
    });

    test('a node set up with full validation keeps it', () async {
      final s = (await repo({
        'settings.onboardingComplete': true,
        'settings.assumeUtreexo': false,
      })).load();
      expect(s.syncMethod, SyncMethod.full);
    });

    test('round-trips the sync method and hints origin', () async {
      final r = await repo();
      final s = const NodeSettings(
        onboardingComplete: true,
        network: BitcoinNetwork.signet,
        hintsOrigin: 'https://mirror.example/hints',
      ).withSyncMethod(SyncMethod.full);
      expect(await r.save(s), const Right(unit));
      expect(r.load(), s);
      expect(r.load().syncMethod, SyncMethod.full);
    });

    test('an invalid stored origin keeps the sync method', () async {
      final s = (await repo({
        'settings.onboardingComplete': true,
        'settings.swiftSync': true,
        'settings.assumeUtreexo': false,
        'settings.hintsOrigin': 'ftp://example.com/hints',
      })).load();
      expect(s.syncMethod, SyncMethod.swiftSync);
      expect(s.hintsOrigin, defaultHintsOrigin);
    });

    test('remembers a node that runs elsewhere', () async {
      final r = await repo();
      const s = NodeSettings(
        onboardingComplete: true,
        network: BitcoinNetwork.signet,
        rpcPort: 48000,
        useExistingNode: true,
      );
      expect(await r.save(s), const Right(unit));
      expect(r.load().useExistingNode, isTrue);
      expect(r.load().effectiveRpcPort, 48000);
      expect(const NodeSettings().useExistingNode, isFalse);
    });

    test('does not save invalid settings', () async {
      final r = await repo();
      final result = await r.save(const NodeSettings(rpcPort: 1));
      expect(result.isLeft(), isTrue);
      expect(r.load(), const NodeSettings());
    });

    test('drops corrupt stored values but keeps onboarding state', () async {
      final r = await repo({
        'settings.onboardingComplete': true,
        'settings.network': 'regtest',
        'settings.dataDir': 'not/absolute',
        'settings.rpcPort': 5,
      });
      final s = r.load();
      expect(s.onboardingComplete, isTrue);
      expect(s.network, BitcoinNetwork.regtest);
      expect(s.dataDir, isNull);
      expect(s.rpcPort, isNull);
    });

    test('falls back to the default network for unknown values', () async {
      final r = await repo({'settings.network': 'testnet3'});
      expect(r.load().network, BitcoinNetwork.bitcoin);
    });

    test('a development build falls back to signet', () async {
      SharedPreferences.setMockInitialValues({});
      final r = SharedPrefsSettingsRepository(
        await SharedPreferences.getInstance(),
        defaultNetwork: BuildFlavor.development.defaultNetwork,
      );
      expect(r.load().network, BitcoinNetwork.signet);
    });

    test('a saved choice wins over the build default', () async {
      final r = await repo({'settings.network': 'signet'});
      expect(r.load().network, BitcoinNetwork.signet);
    });
  });
}
