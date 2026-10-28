/// Opt-in: drives the REAL app UI through installing a REAL florestad
/// artifact with the real `ManagedInstaller`, from a dev-signed manifest
/// served on 127.0.0.1 (no hosting, nothing published):
///
///   FLORESTA_ARTIFACT_DIR=DIR flutter test test/integration/installer_screen_test.dart
///
/// DIR is the output of tool/release/build_florestad_artifact.sh. App data
/// goes to a temp root (`FLORESTA_GUI_DATA_ROOT`), HOME is a temp dir, and
/// PATH has no florestad, so the app starts with "Floresta not found".
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:floresta_gui/app/app.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/providers.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/domain/release_manifest.dart';
import 'package:floresta_gui/features/installation/presentation/install_controller.dart';
import 'package:floresta_gui/features/installation/presentation/installation_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/local_artifact_server.dart';

final _artifactDir = Platform.environment['FLORESTA_ARTIFACT_DIR'];

void main() {
  testWidgets(
    'the Installation screen installs a real artifact, then onboarding continues',
    (tester) async {
      // The widget-test binding fakes every HttpClient (HTTP 400); this test
      // needs real loopback HTTP to the local artifact server.
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previous);
      final platform = HostPlatform.current();
      final info = Directory(_artifactDir!)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.build-info.json'))
          .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>)
          .firstWhere(
            (i) =>
                i['os'] == platform.os.name && i['arch'] == platform.arch.name,
          );
      final name = info['artifact']! as String;

      final key = TestReleaseKey.generate(id: ReleaseSource.developmentKeyId);
      final server = LocalArtifactServer();
      final temp = Directory.systemTemp.createTempSync('floresta_ui_it_');
      await tester.runAsync(() async {
        await server.start();
        server.files['/$name'] = File('$_artifactDir/$name').readAsBytesSync();
        final now = DateTime.now().toUtc();
        server.files['/manifest.json'] = key.envelope({
          'type': ReleaseManifest.type,
          'schema': ReleaseManifest.schema,
          'serial': 1,
          'issued': now.toIso8601String(),
          'expires': now.add(const Duration(days: 1)).toIso8601String(),
          'version': info['version'],
          'upstreamTag': info['upstreamTag'],
          'upstreamCommit': info['upstreamCommit'],
          'artifacts': [
            {
              'os': info['os'],
              'arch': info['arch'],
              'url': name,
              'sha256': info['sha256'],
              'size': info['size'],
            },
          ],
        });
      });
      addTearDown(() async {
        await server.stop();
        if (temp.path.contains('floresta_ui_it_')) {
          temp.deleteSync(recursive: true);
        }
      });

      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final source = ReleaseSource.resolve(
        manifestUrl: '${server.base.resolve('manifest.json')}',
        devKeyHex: key.trusted.publicKeyHex,
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            environmentProvider.overrideWithValue({
              'HOME': '${temp.path}/home',
              'PATH': '/usr/bin:/bin',
              'FLORESTA_GUI_DATA_ROOT': '${temp.path}/data',
            }),
            releaseSourceProvider.overrideWithValue(source),
          ],
          child: const FlorestaApp(),
        ),
      );

      /// Lets real I/O (process probes, sockets, files) progress between
      /// frames until [done] or the deadline.
      Future<void> waitFor(Finder done, {int seconds = 60}) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        // The startup splash covers the app until florestad is detected;
        // nothing underneath can be tapped yet.
        final splash = find.bySemanticsLabel('Floresta is starting');
        while (done.evaluate().isEmpty || splash.evaluate().isNotEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            final texts = find
                .byType(Text)
                .evaluate()
                .map((e) => (e.widget as Text).data)
                .whereType<String>()
                .where(
                  (t) =>
                      t.contains('ownload') ||
                      t.contains('Checking') ||
                      t.contains('Verifying') ||
                      t.contains('Install') ||
                      t.contains('installed'),
                );
            final run = ProviderScope.containerOf(
              tester.element(find.byType(FlorestaApp)),
            ).read(installControllerProvider);
            fail(
              'timed out waiting for $done; install: ${run.progress} '
              'running=${run.running}; screen: ${texts.join(' | ')}',
            );
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          // Moves the fake clock too, so animations (the splash fade) run.
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await waitFor(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await waitFor(find.text('Floresta is not installed'));
      expect(find.text('DEVELOPMENT SOURCE'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);

      // Tapped inside runAsync so the install (downloads, isolates, child
      // processes) runs in the real zone, not the test's fake-async zone.
      await tester.runAsync(() async {
        await tester.tap(find.text('Install Floresta'));
      });
      await waitFor(find.text('Floresta is installed'), seconds: 120);
      await waitFor(
        find.textContaining('Floresta v${info['version']} is ready to use'),
      );
      expect(find.text('Continue'), findsOneWidget);
      expect(
        File(
          '${temp.path}/data/floresta/versions/${info['version']}/florestad',
        ).existsSync(),
        isTrue,
      );
    },
    // Skipped unless FLORESTA_ARTIFACT_DIR is set (testWidgets takes no reason).
    skip: _artifactDir == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
