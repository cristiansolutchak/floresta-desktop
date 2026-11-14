/// The REAL macOS app on public signet (needs internet).
///
///   flutter test integration_test/signet_app_run_test.dart -d macos \
///     --dart-define=FLORESTAD_PATH=/abs/path/to/florestad \
///     --dart-define=FLORESTA_EVIDENCE_DIR=/abs/evidence/dir \
///     --dart-define=FLORESTA_SIGNET_FOLLOW=540
///
/// Compiles and launches the app (real clock, real I/O), starts florestad
/// from the Node screen, records the readiness the app shows over time, and
/// stops it from the screen. App data, chain data and preferences are
/// isolated (temp folders, in-memory preferences); signet Electrum uses its
/// default port 60001, which must be free. Without FLORESTAD_PATH the test
/// is skipped.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _exe = String.fromEnvironment('FLORESTAD_PATH');
const _evidenceDir = String.fromEnvironment('FLORESTA_EVIDENCE_DIR');

/// `signet` (default) or `bitcoin` (mainnet).
const _network = String.fromEnvironment(
  'FLORESTA_NETWORK',
  defaultValue: 'signet',
);

/// Maps to the app's "Disable compact block filters" setting. Used for
/// mainnet runs on machines without ~11 GB to spare for filters.
const _noCfilters = bool.fromEnvironment('FLORESTA_NO_CFILTERS');

/// The run stops the node and fails if the data folder grows past this.
const _maxDataMb = int.fromEnvironment(
  'FLORESTA_MAX_DATA_MB',
  defaultValue: 4000,
);

/// Disk space actually allocated (`du -sk`), not apparent file sizes:
/// florestad pre-allocates sparse files (upstream master reported ~2 GB of
/// apparent size on signet within seconds while using far less).
int _dirBytes(Directory d) {
  if (!d.existsSync()) return 0;
  final r = Process.runSync('/usr/bin/du', ['-sk', d.path]);
  final kb = int.tryParse('${r.stdout}'.split(RegExp(r'\s+')).first) ?? 0;
  return kb * 1024;
}

const _followSeconds = int.fromEnvironment(
  'FLORESTA_SIGNET_FOLLOW',
  defaultValue: 540,
);

void _step(String s) =>
    // ignore: avoid_print
    print('[signet-app ${DateTime.now().toIso8601String()}] $s');

/// Saves what the app window currently shows (real fonts and rendering).
/// Skipped (null) if no frame arrives within 5 s, e.g. display asleep.
Future<String?> _screenshot(String name, [WidgetTester? tester]) async {
  if (_evidenceDir.isEmpty) return null;
  if (tester != null) {
    try {
      await tester.pump().timeout(const Duration(seconds: 5));
    } on Object {
      _step('no frame for screenshot $name (display asleep?); skipped');
      return null;
    }
  }
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  // The root layer is in physical pixels.
  final image = await layer.toImage(
    Offset.zero & view.flutterView.physicalSize,
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_evidenceDir/$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  return path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '$_network: start from the app, follow real readiness, stop from the app',
    (tester) async {
      if (_evidenceDir.isNotEmpty) {
        Directory(_evidenceDir).createSync(recursive: true);
      }
      final temp = Directory.systemTemp.createTempSync('floresta_signet_app_');
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final rpcPort = probe.port;
      await probe.close();

      SharedPreferences.setMockInitialValues({
        'settings.onboardingComplete': true,
        'settings.network': _network,
        'settings.disableCompactFilters': _noCfilters,
        'settings.executablePath': _exe,
        'settings.dataDir': '${temp.path}/data',
        'settings.rpcPort': rpcPort,
        'settings.logToFile': true,
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

      Future<void> waitFor(bool Function() done, Duration limit) async {
        final end = DateTime.now().add(limit);
        while (!done()) {
          if (DateTime.now().isAfter(end)) fail('timed out');
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      final start = find.ancestor(
        of: find.text('Start node'),
        matching: find.byType(TextButton),
      );
      await waitFor(
        () =>
            start.evaluate().isNotEmpty &&
            tester.widget<TextButton>(start).onPressed != null,
        const Duration(seconds: 30),
      );
      final shots = <String?>[await _screenshot('01-before-start', tester)];
      // Never leave a node behind if an assertion fails.
      var stoppedFromScreen = false;
      addTearDown(() async {
        if (stoppedFromScreen) return; // the app (and container) is gone
        final status = container.read(nodeControllerProvider);
        if (status.process.isActive) {
          await container.read(nodeControllerProvider.notifier).stop();
        }
      });
      _step('starting from the Overview banner');
      final started = DateTime.now();
      await tester.tap(start);
      final startDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (!container.read(nodeControllerProvider).process.isActive) {
        await tester.pump(const Duration(milliseconds: 200));
        final snack = find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(Text),
        );
        if (snack.evaluate().isNotEmpty) {
          await _screenshot('01b-start-refused', tester);
          fail(
            'The app refused to start: '
            '${tester.widget<Text>(snack.first).data}',
          );
        }
        if (DateTime.now().isAfter(startDeadline)) {
          fail('The node did not start within 20 s');
        }
      }

      final timeline = <Map<String, Object?>>[];
      String? lastKey;
      final seenStages = <ReadinessStage>{};
      final end = started.add(const Duration(seconds: _followSeconds));
      var dataMb = 0;
      var lastSizeCheck = DateTime.fromMillisecondsSinceEpoch(0);
      while (DateTime.now().isBefore(end)) {
        // Real time drives the loop (the app's timers keep running even if
        // macOS stops producing frames when the display sleeps), but a frame
        // is still requested each tick so the window keeps repainting; the
        // timeout keeps a sleeping display from hanging the run.
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          await tester.pump().timeout(const Duration(seconds: 2));
        } on Object {
          // No frame (display asleep): keep following on real time.
        }
        if (DateTime.now().difference(lastSizeCheck).inSeconds >= 30) {
          lastSizeCheck = DateTime.now();
          dataMb = _dirBytes(Directory('${temp.path}/data')) ~/ (1 << 20);
          if (dataMb > _maxDataMb) {
            _step('data folder at $dataMb MB > $_maxDataMb MB; stopping');
            await container.read(nodeControllerProvider.notifier).stop();
            fail('Data folder exceeded $_maxDataMb MB ($dataMb MB)');
          }
        }
        final status = container.read(nodeControllerProvider);
        final r = container.read(nodeReadinessProvider);
        final chain = status.chain;
        final peers = status.peers ?? const [];
        final key =
            '${status.process.runtimeType}|${r.stage}|'
            '${(chain?.headerHeight ?? 0) ~/ 1000}|${chain?.validatedHeight}|'
            '${r.missingUtreexoPeers}|${r.electrum}|${peers.length}|'
            '${r.stalledFor != null}';
        if (key == lastKey) continue;
        lastKey = key;
        timeline.add({
          'atSeconds': DateTime.now().difference(started).inSeconds,
          'process': status.process.runtimeType.toString(),
          'stage': r.stage.name,
          'headers': chain?.headerHeight,
          'validated': chain?.validatedHeight,
          'ibd': chain?.initialBlockDownload,
          'peers': peers.length,
          'utreexoPeers': peers.where((p) => p.supportsUtreexo).length,
          'peerServicesSample': peers.isEmpty ? null : peers.first.services,
          'missingUtreexoPeers': r.missingUtreexoPeers,
          'electrum': r.electrum.name,
          'stalledSeconds': r.stalledFor?.inSeconds,
          'dataMb': dataMb,
        });
        if (seenStages.add(r.stage)) {
          shots.add(await _screenshot('02-${r.stage.name}', tester));
        }
        _step(
          '${r.stage.name} headers=${chain?.headerHeight} '
          'validated=${chain?.validatedHeight} peers=${peers.length}',
        );
        if (r.usable) break;
      }
      shots.add(await _screenshot('03-after-follow', tester));

      final evidence = {
        'test': 'integration_test/signet_app_run_test.dart',
        'date': DateTime.now().toUtc().toIso8601String(),
        'florestad': _exe,
        'network': _network,
        'compactFilters': !_noCfilters,
        'followedSeconds': DateTime.now().difference(started).inSeconds,
        'screenshots': shots.whereType<String>().toList(),
        'timeline': timeline,
      };
      final json = const JsonEncoder.withIndent('  ').convert(evidence);
      if (_evidenceDir.isNotEmpty) {
        File('$_evidenceDir/app-run.json').writeAsStringSync(json);
      }
      _step('evidence: $json');

      expect(seenStages, contains(ReadinessStage.downloadingHeaders));
      expect(timeline.any((t) => (t['headers'] as int? ?? 0) > 100000), isTrue);

      _step('stopping from the Overview banner');
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await waitFor(
        () => container.read(nodeControllerProvider).process is ProcessStopped,
        const Duration(seconds: 90),
      );
      await tester.pump(const Duration(seconds: 1));
      await _screenshot('04-stopped', tester);
      expect(find.text('Start node'), findsOneWidget);
      stoppedFromScreen = true;
      temp.deleteSync(recursive: true);
    },
    skip: _exe.isEmpty,
    timeout: Timeout(Duration(seconds: _followSeconds + 360)),
  );
}
