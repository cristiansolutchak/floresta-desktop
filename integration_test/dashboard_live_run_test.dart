/// UX-03/04: the REAL macOS app with a syncing node.
///
///   flutter test integration_test/dashboard_live_run_test.dart -d macos \
///     --dart-define=FLORESTAD_PATH=/abs/path/to/florestad \
///     --dart-define=FLORESTA_DATA_DIR=/abs/copy/of/a/data/dir \
///     --dart-define=FLORESTA_EVIDENCE_DIR=/abs/evidence/dir
///
/// Starts florestad from the Overview banner on [FLORESTA_NETWORK] (mainnet
/// by default) with a data folder from an earlier run, so the node is
/// verifying blocks within minutes instead of downloading every header.
/// Once it verifies blocks, the Overview and Sync screens are captured and
/// every number they show is compared with what the node itself answers
/// over JSON-RPC (`getblockchaininfo`, `getpeerinfo`) at the same moment.
/// Then the node is stopped from the banner. The data folder is modified
/// (pass a copy). Electrum's default port must be free. Without
/// FLORESTAD_PATH the test is skipped.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/presentation/node_controller.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _exe = String.fromEnvironment('FLORESTAD_PATH');
const _dataDir = String.fromEnvironment('FLORESTA_DATA_DIR');
const _evidenceDir = String.fromEnvironment('FLORESTA_EVIDENCE_DIR');
const _network = String.fromEnvironment(
  'FLORESTA_NETWORK',
  defaultValue: 'bitcoin',
);

/// How long to wait for the node to verify blocks.
const _waitMinutes = int.fromEnvironment(
  'FLORESTA_WAIT_MINUTES',
  defaultValue: 15,
);

void _step(String s) =>
    // ignore: avoid_print
    print('[dashboard-live ${DateTime.now().toIso8601String()}] $s');

Future<String?> _screenshot(WidgetTester tester, String name) async {
  if (_evidenceDir.isEmpty) return null;
  try {
    await tester.pump().timeout(const Duration(seconds: 5));
  } on Object {
    _step('no frame for screenshot $name (display asleep?); skipped');
    return null;
  }
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final image = await layer.toImage(
    Offset.zero & view.flutterView.physicalSize,
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final path = '$_evidenceDir/$name.png';
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
  return path;
}

/// Independent JSON-RPC call, not through the app's repository.
Future<Object?> _rpc(int port, String method) async {
  final client = HttpClient();
  try {
    final req = await client
        .post('127.0.0.1', port, '/')
        .timeout(const Duration(seconds: 10));
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': <Object?>[],
      }),
    );
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    return (jsonDecode(body) as Map)['result'];
  } finally {
    client.close(force: true);
  }
}

/// Every text on screen, in tree order.
List<String> _texts(WidgetTester tester) => [
  for (final e in find.byType(RichText).evaluate())
    (e.widget as RichText).text.toPlainText(),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Overview and Sync show what the node reports while it syncs',
    (tester) async {
      if (_evidenceDir.isNotEmpty) {
        Directory(_evidenceDir).createSync(recursive: true);
      }
      final temp = Directory.systemTemp.createTempSync('floresta_dash_live_');
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final rpcPort = probe.port;
      await probe.close();

      SharedPreferences.setMockInitialValues({
        'settings.onboardingComplete': true,
        'settings.network': _network,
        'settings.disableCompactFilters': true,
        'settings.executablePath': _exe,
        'settings.dataDir': _dataDir.isEmpty ? '${temp.path}/data' : _dataDir,
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

      Future<void> follow(bool Function() done, Duration limit) async {
        final end = DateTime.now().add(limit);
        while (!done()) {
          if (DateTime.now().isAfter(end)) fail('timed out');
          await Future<void>.delayed(const Duration(seconds: 1));
          try {
            await tester.pump().timeout(const Duration(seconds: 2));
          } on Object {
            // Display asleep: keep following on real time.
          }
        }
      }

      final start = find.ancestor(
        of: find.text('Start node'),
        matching: find.byType(TextButton),
      );
      await follow(
        () =>
            start.evaluate().isNotEmpty &&
            tester.widget<TextButton>(start).onPressed != null,
        const Duration(seconds: 30),
      );
      final shots = <String?>[await _screenshot(tester, '01-stopped')];
      var stopped = false;
      addTearDown(() async {
        if (stopped) return;
        final status = container.read(nodeControllerProvider);
        if (status.process.isActive) {
          await container.read(nodeControllerProvider.notifier).stop();
        }
      });

      _step('starting from the Overview banner (RPC port $rpcPort)');
      await tester.tap(start);
      await follow(
        () => container.read(nodeControllerProvider).process.isActive,
        const Duration(seconds: 20),
      );

      // Verifying blocks (or stalled there) with peers, for a minute so the
      // app has polled peers, Electrum and the peer tip.
      int? firstValidated;
      DateTime? verifyingSince;
      var lastLog = DateTime.now();
      await follow(() {
        final s = container.read(nodeControllerProvider);
        final r = container.read(nodeReadinessProvider);
        final v = s.chain?.validatedHeight;
        if (v != null && v > 0) firstValidated ??= v;
        if (DateTime.now().difference(lastLog).inSeconds >= 30) {
          lastLog = DateTime.now();
          _step(
            '${r.stage.name} headers=${s.chain?.headerHeight} '
            'validated=$v peers=${s.peers?.length}',
          );
        }
        final verifying =
            r.stage == ReadinessStage.validatingBlocks &&
            (s.peers?.isNotEmpty ?? false) &&
            v != null &&
            v > 0;
        if (!verifying) {
          verifyingSince = null;
          return false;
        }
        verifyingSince ??= DateTime.now();
        return DateTime.now().difference(verifyingSince!).inSeconds >= 60;
      }, const Duration(minutes: _waitMinutes));

      final checks = <Map<String, Object?>>[];
      Future<Map<String, Object?>> compare(String screen) async {
        await tester.pump();
        final shown = _texts(tester);
        final info = (await _rpc(rpcPort, 'getblockchaininfo'))! as Map;
        final peers = (await _rpc(rpcPort, 'getpeerinfo'))! as List;
        final ready = peers
            .cast<Map>()
            .where((p) => '${p['state']}'.toLowerCase() == 'ready')
            .toList();
        final r = container.read(nodeReadinessProvider);
        final headers = info['height'] as int;
        final validated = info['validated'] as int;
        // The app polls every few seconds; the node moves meanwhile.
        bool near(String prefix, int value, {String suffix = ''}) =>
            shown.any((t) {
              if (!t.startsWith(prefix) || !t.endsWith(suffix)) return false;
              final digits = t
                  .substring(prefix.length, t.length - suffix.length)
                  .replaceAll(',', '');
              final n = int.tryParse(digits);
              return n != null && (n - value).abs() <= 5;
            });
        final tip = max(r.peerTip ?? 0, headers);
        final result = {
          'screen': screen,
          'rpc': {
            'height': headers,
            'validated': validated,
            'progress': info['progress'],
            'peers': peers.length,
            'ready': ready.length,
            'inbound': ready.where((p) => p['inbound'] == true).length,
            'v1': ready.where((p) => p['transport_protocol'] == 'V1').length,
            'v2': ready.where((p) => p['transport_protocol'] == 'V2').length,
          },
          'peerTipEstimate': r.peerTip,
          'headerHeightShown': near('Height: ', headers),
          'validatedShown': near('', validated),
          'tipShown': near('', tip),
          'readyCountShown': shown.contains('${ready.length} Connected'),
          'progressNotShown': !shown.any(
            (t) => t.contains(
              ((info['progress'] as num) * 100).toStringAsFixed(1),
            ),
          ),
          'texts': shown,
        };
        _step('$screen: ${jsonEncode({...result, 'texts': null})}');
        checks.add(result);
        return result;
      }

      shots.add(await _screenshot(tester, '02-overview'));
      final overview = await compare('overview');
      // A node waiting on Utreexo peers for long is "Stalled"; both are
      // real states of a syncing node.
      final banner = _texts(tester).firstWhere((t) => t.startsWith('Status: '));
      _step('banner: $banner');
      expect(banner, anyOf('Status: SYNCING', 'Status: STALLED'));
      expect(find.text('Phase: Blocks'), findsOneWidget);
      expect(overview['headerHeightShown'], isTrue);
      expect(overview['validatedShown'], isTrue);
      expect(overview['tipShown'], isTrue);
      expect(overview['progressNotShown'], isTrue);

      await tester.ensureVisible(find.text('View Peers'));
      await tester.pump(const Duration(milliseconds: 300));
      shots.add(await _screenshot(tester, '02b-overview-lower'));
      await tester.tap(find.text('View Peers'));
      await tester.pump(const Duration(milliseconds: 500));
      shots.add(await _screenshot(tester, '03-peers-dialog'));
      final rows = find.textContaining(RegExp(r'^\[?[0-9a-f.:\[\]]+:\d+'));
      _step('peer rows in dialog: ${rows.evaluate().length}');
      await tester.tap(find.byTooltip('Close'));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Sync').first);
      await tester.pump(const Duration(seconds: 1));
      shots.add(await _screenshot(tester, '04-sync'));
      await tester.ensureVisible(find.text('Verification details'));
      await tester.pump(const Duration(milliseconds: 500));
      shots.add(await _screenshot(tester, '05-sync-details'));
      final sync = await compare('sync');
      expect(
        find.text('Step 2/3 – Downloading & Verifying Blocks'),
        findsOneWidget,
      );
      expect(sync['validatedShown'], isTrue);
      expect(sync['tipShown'], isTrue);
      expect(find.text('Accepted from snapshot'), findsOneWidget);

      final network = BitcoinNetwork.values.firstWhere(
        (n) => n.name == _network,
      );
      final evidence = {
        'test': 'integration_test/dashboard_live_run_test.dart',
        'date': DateTime.now().toUtc().toIso8601String(),
        'florestad': _exe,
        'network': network.name,
        'firstValidatedSeen': firstValidated,
        'lastValidatedSeen': container
            .read(nodeControllerProvider)
            .chain
            ?.validatedHeight,
        'screenshots': shots.whereType<String>().toList(),
        'checks': checks,
      };
      if (_evidenceDir.isNotEmpty) {
        File('$_evidenceDir/dashboard-live.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
      }

      _step('stopping from the Overview banner');
      await tester.tap(find.text('Overview').first);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Stop'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
      await follow(
        () => container.read(nodeControllerProvider).process is ProcessStopped,
        const Duration(seconds: 90),
      );
      await tester.pump(const Duration(seconds: 1));
      shots.add(await _screenshot(tester, '06-stopped-again'));
      expect(find.text('Start node'), findsOneWidget);
      stopped = true;
      temp.deleteSync(recursive: true);
    },
    skip: _exe.isEmpty,
    timeout: const Timeout(Duration(minutes: _waitMinutes + 10)),
  );
}
