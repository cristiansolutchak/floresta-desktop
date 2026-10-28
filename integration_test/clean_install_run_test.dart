/// INS-02 / INS-15 (C3, C5, C6, C8): the REAL macOS app, built with a
/// release configuration, on a profile with no florestad anywhere: it
/// installs florestad from the configured source through the onboarding
/// screen, configures it in the wizard, starts it from Finish, stops it,
/// then finds the managed install again after a restart. Finally it
/// deletes the node data and removes that florestad from Settings (INS-12).
///
///   dart run tool/release/release_tool.dart serve --artifacts RELEASE_DIR
///   flutter test integration_test/clean_install_run_test.dart -d macos \
///     --dart-define-from-file=config/release/development.json \
///     --dart-define=FLORESTA_CLEAN_RUN=true \
///     --dart-define=FLORESTA_EVIDENCE_DIR=/abs/evidence/dir
///
/// Uses the release source compiled into the build (no test override), an
/// empty temporary home, app-data root and data folder, and
/// `PATH=/usr/bin:/bin`. Regtest, so it needs no internet beyond the release
/// server; the default regtest ports 18442 and 20001 must be free. Skipped
/// unless FLORESTA_CLEAN_RUN=true.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OffsetLayer, RendererBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('FLORESTA_CLEAN_RUN');
const _evidenceDir = String.fromEnvironment('FLORESTA_EVIDENCE_DIR');

void _step(String s) =>
    // ignore: avoid_print
    print('[clean-run ${DateTime.now().toIso8601String()}] $s');

Future<void> _screenshot(String name, WidgetTester tester) async {
  if (_evidenceDir.isEmpty) return;
  try {
    await tester.pump().timeout(const Duration(seconds: 5));
  } on Object {
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

  testWidgets(
    'clean profile: install from the release source, configure, run, restart',
    (tester) async {
      final source = ReleaseSource.fromEnvironment();
      expect(
        source,
        isNotNull,
        reason: 'build with a release configuration (see header)',
      );
      _step('release source compiled in: ${source!.manifestUrl}');
      if (_evidenceDir.isNotEmpty) {
        Directory(_evidenceDir).createSync(recursive: true);
      }
      final temp = Directory.systemTemp.createTempSync('floresta_clean_');
      final env = {
        'HOME': '${temp.path}/home',
        'PATH': '/usr/bin:/bin',
        'FLORESTA_GUI_DATA_ROOT': '${temp.path}/app',
      };
      Directory(env['HOME']!).createSync(recursive: true);

      // Only the data folder is preset: florestad inherits the real HOME,
      // and the native folder picker cannot be automated.
      SharedPreferences.setMockInitialValues({
        'settings.dataDir': '${temp.path}/data',
      });
      final prefs = await SharedPreferences.getInstance();

      Future<ProviderContainer> launch() async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              environmentProvider.overrideWithValue(env),
            ],
            child: const FlorestaApp(),
          ),
        );
        return ProviderScope.containerOf(
          tester.element(find.byType(FlorestaApp)),
        );
      }

      var container = await launch();
      var stopped = false;
      addTearDown(() async {
        if (stopped) return;
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

      Future<void> tap(String text) async {
        await waitFor(find.text(text));
        await tester.ensureVisible(find.text(text).last);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text(text).last);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await waitFor(find.text('Welcome to Floresta'));
      await tap('Get started');
      await waitFor(find.text('Install Floresta'));
      await _screenshot('01-not-installed', tester);
      _step('installing from the release source');
      final installStart = DateTime.now();
      await tap('Install Floresta');
      await waitFor(find.text('Floresta is installed'), 180);
      _step('installed in ${DateTime.now().difference(installStart)}');
      await waitFor(find.textContaining('Floresta v0.9.1 is ready to use'));
      await _screenshot('02-installed', tester);
      final installed = await container.read(
        installationDetectionProvider.future,
      );
      final exe = installed.getOrElse((f) => fail(f.message)).executablePath;
      _step('managed executable: $exe');
      expect(exe, startsWith('${temp.path}/app'));

      await tap('Continue');
      await waitFor(find.text('Choose a network'));
      if (find.text('Regtest').evaluate().isEmpty) {
        await tap('Test networks (advanced)');
      }
      await tap('Regtest');
      await tap('Next');
      await waitFor(find.textContaining('free on this disk'));
      await tap('Next');
      await tap('Next');
      await tap('Review configuration');
      await _screenshot('03-review', tester);
      await tap('Finish');

      final end = DateTime.now().add(const Duration(seconds: 60));
      while (container.read(nodeControllerProvider).api !=
          ApiReachability.reachable) {
        if (DateTime.now().isAfter(end)) {
          fail('API not reachable: ${container.read(nodeControllerProvider)}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          await tester.pump().timeout(const Duration(seconds: 2));
        } on Object {
          // Display asleep: keep waiting on real time.
        }
      }
      _step('node running from the managed install, API reachable');
      await _screenshot('04-running', tester);
      expect(
        (await container.read(nodeControllerProvider.notifier).stop())
            .isRight(),
        isTrue,
      );
      _step('stopped');

      // C8: a new app session finds the managed install and the settings.
      container = await launch();
      await waitFor(find.text('Start node'));
      final again = await container.read(installationDetectionProvider.future);
      expect(again.getOrElse((f) => fail(f.message)).executablePath, exe);
      await _screenshot('05-after-restart', tester);
      stopped = true;
      _step('restart found the managed install');

      // INS-12 on the real files florestad wrote: delete the node data, then
      // remove the installed Floresta, both from Settings.
      final netDir = Directory('${temp.path}/data/regtest');
      expect(Directory('${netDir.path}/chaindata').existsSync(), isTrue);
      File('${netDir.path}/keep-me.txt').writeAsStringSync('user file');
      await tap('Settings');
      await tap('Delete node data…');
      await waitFor(find.text('Delete the node data?'));
      await _screenshot('06-delete-confirm', tester);
      await tap('Delete node data');
      await waitFor(find.textContaining('Deleted '));
      final left = netDir.listSync().map((e) => e.path.split('/').last).toSet();
      _step('node data after delete: $left');
      expect(left, {'keep-me.txt'});

      await tap('Remove Floresta…');
      await tap('Remove Floresta');
      await waitFor(find.text('The installed Floresta was removed.'));
      expect(File(exe).existsSync(), isFalse);
      final gone = await container.read(installationDetectionProvider.future);
      expect(gone.isLeft(), isTrue);
      _step('managed florestad removed; detection: ${gone.getLeft()}');
      await _screenshot('07-after-removal', tester);
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
