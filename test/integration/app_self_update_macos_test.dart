/// Opt-in end-to-end check of the app updater on macOS with a REAL app
/// bundle and the real system tools (ditto, plutil, codesign, /bin/sh):
///
///   flutter build macos --release   # or tool/build_app.sh
///   FLORESTA_APP_BUNDLE=build/macos/Build/Products/Release/Floresta.app \
///     flutter test test/integration/app_self_update_macos_test.dart
///
/// The bundle is copied into a temp "Applications" folder as the installed
/// version. An "update" is made from another copy (version raised, ad-hoc
/// re-signed, zipped with ditto) and published by a signed app manifest on
/// 127.0.0.1 with a key created at runtime. The updater checks, downloads,
/// verifies, unpacks and arms the swap; the helper waits for a stand-in
/// process to exit, then swaps. The GUI is not launched, so quitting and
/// relaunching the real app is not covered here.
@Tags(['integration'])
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/features/installation/data/app_updater.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/domain/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/local_artifact_server.dart';

final _bundle = Platform.environment['FLORESTA_APP_BUNDLE'];

Future<String> _plist(String app, String key) async =>
    '${(await Process.run('/usr/bin/plutil', ['-extract', key, 'raw', '-o', '-', '$app/Contents/Info.plist'])).stdout}'
        .trim();

Future<void> _ok(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  expect(r.exitCode, 0, reason: '$exe ${args.join(' ')}: ${r.stderr}');
}

void main() {
  test(
    'checks, verifies and swaps a real Floresta.app',
    () async {
      final source = Directory(_bundle!).absolute.path;
      final current = await _plist(source, 'CFBundleShortVersionString');
      final now = AppVersion.tryParse(current)!;
      final next = AppVersion(now.major, now.minor, now.patch + 1);

      final root = await Directory.systemTemp.createTemp('floresta_selfupd_');
      addTearDown(() async {
        if (root.path.contains('floresta_selfupd_')) {
          await root.delete(recursive: true);
        }
      });
      final apps = Directory('${root.path}/Applications')..createSync();
      final installed = '${apps.path}/Floresta.app';
      await _ok('/usr/bin/ditto', [source, installed]);

      // The update: same app, next version, re-signed (ad-hoc), zipped.
      final work = Directory('${root.path}/build')..createSync();
      final newer = '${work.path}/Floresta.app';
      await _ok('/usr/bin/ditto', [source, newer]);
      await _ok('/usr/bin/plutil', [
        '-replace',
        'CFBundleShortVersionString',
        '-string',
        '$next',
        '$newer/Contents/Info.plist',
      ]);
      await _ok('/usr/bin/codesign', [
        '--force',
        '--deep',
        '--sign',
        '-',
        newer,
      ]);
      final zip = '${work.path}/Floresta-$next-macos-universal-unsigned.zip';
      await _ok('/usr/bin/ditto', ['-c', '-k', '--keepParent', newer, zip]);
      final zipBytes = File(zip).readAsBytesSync();

      final server = LocalArtifactServer();
      await server.start();
      addTearDown(server.stop);
      final key = TestReleaseKey.generate(id: 'dev');
      final issued = DateTime.now().toUtc();
      server.files['/app/pkg.zip'] = zipBytes;
      server.files['/app/manifest.json'] = key.envelope({
        'type': AppReleaseManifest.type,
        'schema': AppReleaseManifest.schema,
        'serial': 1,
        'issued': issued.toIso8601String(),
        'expires': issued.add(const Duration(days: 1)).toIso8601String(),
        'version': '$next',
        'notes': 'Integration test build.',
        'artifacts': [
          {
            'os': 'macos',
            'arch': 'universal',
            'format': 'macos-app-zip',
            'url': 'pkg.zip',
            'sha256': BytesUtils.toHexString(QuickCrypto.sha256Hash(zipBytes)),
            'size': zipBytes.length,
          },
        ],
      });

      final platform = HostPlatform.current();
      final kind = classifyAppInstall(
        os: platform.os,
        resolvedExecutable: '$installed/Contents/MacOS/Floresta',
        isWritable: (dir) => Directory(dir).existsSync(),
        releaseBuild: true,
        updatesEnabled: true,
      );
      expect(kind, isA<SelfUpdatable>());
      final updater = AppUpdater(
        paths: AppPaths(Directory('${root.path}/data')),
        source: ReleaseSource(
          manifestUrl: server.base.resolve('florestad/manifest.json'),
          trustedKeys: [key.trusted],
        ),
        platform: platform,
      );

      final offer = (await updater.check(
        current: now,
        kind: kind,
      )).getOrElse((f) => fail(f.message));
      expect(offer?.version, next);
      final staged = (await updater.download(
        offer!,
      )).getOrElse((f) => fail(f.message));
      expect(staged.path, '${apps.path}/.floresta-update-$next/Floresta.app');
      // Still the old version until the app has quit.
      expect(await _plist(installed, 'CFBundleShortVersionString'), current);

      // Stand-in for the running app: the helper waits for it to exit.
      final app = await Process.start('/bin/sleep', ['2']);
      final armed = await updater.armSwap(
        staged,
        kind as SelfUpdatable,
        pid: app.pid,
        relaunch: false,
      );
      expect(armed.isRight(), isTrue, reason: '$armed');
      expect(updater.swapPending, isTrue);
      await app.exitCode;

      SwapResult? result;
      for (var i = 0; i < 40 && result == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        result = await updater.lastResult();
      }
      expect(result?.ok, isTrue, reason: result?.reason);
      expect(await _plist(installed, 'CFBundleShortVersionString'), '$next');
      await _ok('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        installed,
      ]);
      final backup = '${apps.path}/.floresta-previous-Floresta.app';
      expect(await _plist(backup, 'CFBundleShortVersionString'), current);
      expect(updater.swapPending, isFalse);

      // The new version, once running, clears the backup and downloads.
      await updater.finish(result!);
      expect(Directory(backup).existsSync(), isFalse);
      expect(await updater.lastResult(), isNull);
    },
    skip: _bundle == null
        ? 'set FLORESTA_APP_BUNDLE to a release Floresta.app'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
