/// UX-02: the REAL macOS app from first launch to a running node, through
/// the setup wizard only (no preferences pre-set except the executable).
///
///   flutter test integration_test/onboarding_wizard_run_test.dart -d macos \
///     --dart-define=FLORESTAD_PATH=/abs/path/to/florestad \
///     --dart-define=FLORESTA_NETWORK=regtest \
///     --dart-define=FLORESTA_EVIDENCE_DIR=/abs/evidence/dir
///
/// `FLORESTA_NETWORK` is `regtest` (default, offline) or `signet` (needs
/// internet). On signet the run also turns off "Backfill in background" in
/// the wizard and checks that florestad got `--no-backfill`. Home, app data
/// preferences and the data folder are isolated; the network's default RPC and Electrum
/// ports must be free. Without FLORESTAD_PATH the test is skipped.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/presentation/settings_controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _exe = String.fromEnvironment('FLORESTAD_PATH');
const _evidenceDir = String.fromEnvironment('FLORESTA_EVIDENCE_DIR');
const _networkName = String.fromEnvironment(
  'FLORESTA_NETWORK',
  defaultValue: 'regtest',
);

void _step(String s) =>
    // ignore: avoid_print
    print('[wizard-run ${DateTime.now().toIso8601String()}] $s');

Future<void> _screenshot(String name, WidgetTester tester) async {
  if (_evidenceDir.isEmpty) return;
  try {
    await tester.pump().timeout(const Duration(seconds: 5));
  } on Object {
    _step('no frame for screenshot $name (display asleep?); skipped');
    return;
  }
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final image = await layer.toImage(
    Offset.zero & view.flutterView.physicalSize,
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('$_evidenceDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final network = BitcoinNetwork.fromCliValue(_networkName)!;

  testWidgets(
    '$_networkName: first launch, wizard, Finish starts a real node',
    (tester) async {
      if (_evidenceDir.isNotEmpty) {
        Directory(_evidenceDir).createSync(recursive: true);
      }
      final temp = Directory.systemTemp.createTempSync('floresta_wizard_');
      SharedPreferences.setMockInitialValues({
        // The install step finds the executable; everything else comes
        // from the wizard. The data folder is preset because florestad
        // inherits the real HOME and the native folder picker cannot be
        // driven here: the default would write to the user's ~/.floresta.
        'settings.executablePath': _exe,
        'settings.dataDir': '${temp.path}/data',
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            environmentProvider.overrideWithValue({
              'HOME': '${temp.path}/home',
              'PATH': '/usr/bin:/bin',
              'FLORESTA_GUI_DATA_ROOT': '${temp.path}/app',
            }),
          ],
          child: const FlorestaApp(),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(FlorestaApp)),
      );
      var stopped = false;
      addTearDown(() async {
        if (stopped) return; // the app (and container) is gone
        if (container.read(nodeControllerProvider).process.isActive) {
          await container.read(nodeControllerProvider.notifier).stop();
        }
      });

      Future<void> waitFor(Finder f, [int seconds = 30]) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        // The startup splash covers the app until florestad is detected;
        // nothing underneath can be tapped yet.
        final splash = find.bySemanticsLabel('Floresta is starting');
        while (f.evaluate().isEmpty || splash.evaluate().isNotEmpty) {
          if (DateTime.now().isAfter(end)) fail('timed out waiting for $f');
          await tester.pump(const Duration(milliseconds: 200));
        }
      }

      Future<void> tap(String text, {String? shot}) async {
        await waitFor(find.text(text));
        await tester.ensureVisible(find.text(text).last);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text(text).last);
        await tester.pump(const Duration(milliseconds: 300));
        if (shot != null) await _screenshot(shot, tester);
      }

      await waitFor(find.text('Welcome to Floresta'));
      await _screenshot('01-welcome', tester);
      await tap('Get started');
      await waitFor(find.textContaining('is ready to use'));
      await _screenshot('02-install', tester);
      await tap('Continue');

      await waitFor(find.text('Choose a network'));
      if (find.text(network.label).evaluate().isEmpty) {
        await tap('Test networks (advanced)');
      }
      await tap(network.label, shot: '03-network');
      await tap('Next');
      await waitFor(find.textContaining('free on this disk'));
      expect(find.text('${temp.path}/data/${network.dataSubdir}'), findsOne);
      await _screenshot('04-storage', tester);
      await tap('Next', shot: '05-fast-start');
      final turnOffBackfill = network.assumeUtreexoHeight > 0;
      if (turnOffBackfill) {
        final backfill = find.textContaining('Backfill in background');
        await tester.ensureVisible(backfill);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(backfill);
        await tester.pump(const Duration(milliseconds: 300));
        await waitFor(find.text('History stays assumed'));
      } else {
        await waitFor(find.text('Validates from the first block'));
      }
      await tap('Next', shot: '06-services');
      await tap('Review configuration', shot: '07-review');
      _step('finishing the wizard with "Start Floresta now"');
      await tap('Finish');

      final settings = container.read(settingsControllerProvider);
      expect(settings.onboardingComplete, isTrue);
      expect(settings.network, network);
      expect(settings.backfill, !turnOffBackfill);
      expect(prefs.getBool('settings.onboardingComplete'), isTrue);

      final end = DateTime.now().add(const Duration(seconds: 60));
      while (container.read(nodeControllerProvider).api !=
          ApiReachability.reachable) {
        if (DateTime.now().isAfter(end)) {
          fail(
            'The node API did not answer within 60 s: '
            '${container.read(nodeControllerProvider).process}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          await tester.pump().timeout(const Duration(seconds: 2));
        } on Object {
          // Display asleep: keep waiting on real time.
        }
      }
      _step('node API reachable: ${container.read(nodeControllerProvider)}');
      await _screenshot('08-node-running', tester);

      // The real command line florestad was given.
      final ps = Process.runSync('/bin/ps', ['-axo', 'args']);
      final line = '${ps.stdout}'
          .split('\n')
          .firstWhere((l) => l.contains('${temp.path}/data'));
      _step('florestad args: $line');
      expect(line, contains('--network ${network.cliValue}'));
      expect(line.contains('--no-backfill'), turnOffBackfill);
      expect(line, isNot(contains('--no-assume-utreexo')));

      expect(
        (await container.read(nodeControllerProvider.notifier).stop())
            .isRight(),
        isTrue,
      );
      stopped = true;
    },
    skip: _exe.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
