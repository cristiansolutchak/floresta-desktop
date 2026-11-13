import 'dart:convert';
import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/features/installation/data/app_updater.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/domain/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/local_artifact_server.dart';

String _sha(List<int> b) => BytesUtils.toHexString(QuickCrypto.sha256Hash(b));

Map<String, Object?> _payload({
  String version = '0.0.2',
  int serial = 1,
  List<Map<String, Object?>> artifacts = const [],
  String type = AppReleaseManifest.type,
}) {
  final now = DateTime.now().toUtc();
  return {
    'type': type,
    'schema': AppReleaseManifest.schema,
    'serial': serial,
    'issued': now.toIso8601String(),
    'expires': now.add(const Duration(days: 30)).toIso8601String(),
    'version': version,
    'notes': 'Fixes things.',
    'artifacts': artifacts,
  };
}

void main() {
  group('AppVersion', () {
    test('parses pubspec style and compares', () {
      expect(AppVersion.tryParse('0.0.1+1'), const AppVersion(0, 0, 1));
      expect(AppVersion.tryParse('v1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(const AppVersion(0, 1, 0) > const AppVersion(0, 0, 9), isTrue);
      expect(const AppVersion(1, 0, 0) > const AppVersion(1, 0, 0), isFalse);
    });
  });

  group('AppReleaseManifest', () {
    final base = Uri.parse('https://r.example/app/manifest.json');
    final entry = {
      'os': 'macos',
      'arch': 'universal',
      'format': 'macos-app-zip',
      'url': 'Floresta-0.0.2-macos-universal.zip',
      'sha256': 'ab' * 32,
      'size': 10,
    };

    test('a universal macOS package matches both Mac architectures', () {
      final m = AppReleaseManifest.parse(
        _payload(artifacts: [entry]),
        base,
      ).getOrElse((f) => fail(f.message));
      expect(m.version, const AppVersion(0, 0, 2));
      expect(m.notes, 'Fixes things.');
      const arm = HostPlatform(HostOs.macos, CpuArch.arm64);
      const intel = HostPlatform(HostOs.macos, CpuArch.x64);
      expect(m.artifactFor(arm, AppPackageFormat.macosAppZip), isNotNull);
      expect(m.artifactFor(intel, AppPackageFormat.macosAppZip), isNotNull);
      expect(m.artifactFor(arm, AppPackageFormat.linuxTarGz), isNull);
      expect(
        m.artifacts.single.url.toString(),
        'https://r.example/app/Floresta-0.0.2-macos-universal.zip',
      );
    });

    test('a florestad manifest never passes as an app manifest', () {
      expect(
        AppReleaseManifest.parse(
          _payload(type: 'floresta-gui/release-manifest'),
          base,
        ).isLeft(),
        isTrue,
      );
    });

    test('bad entries are refused', () {
      for (final bad in [
        {...entry, 'format': 'exe'},
        {...entry, 'arch': 'mips'},
        {...entry, 'sha256': 'xyz'},
        {...entry, 'size': 0},
      ]) {
        expect(
          AppReleaseManifest.parse(_payload(artifacts: [bad]), base).isLeft(),
          isTrue,
          reason: '$bad',
        );
      }
    });
  });

  group('classifyAppInstall', () {
    AppInstallKind classify(
      HostOs os,
      String exe, {
      bool writable = true,
      bool release = true,
    }) => classifyAppInstall(
      os: os,
      resolvedExecutable: exe,
      isWritable: (_) => writable,
      releaseBuild: release,
      updatesEnabled: true,
    );

    test('a Mac app in a writable folder replaces itself', () {
      expect(
        classify(
          HostOs.macos,
          '/Applications/Floresta.app/Contents/MacOS/Floresta',
        ),
        const SelfUpdatable(
          AppPackageFormat.macosAppZip,
          '/Applications/Floresta.app',
          executable: '/Applications/Floresta.app',
        ),
      );
    });

    test('from the disk image, translocated or unwritable: notice only', () {
      expect(
        classify(
          HostOs.macos,
          '/Volumes/Floresta/Floresta.app/Contents/MacOS/Floresta',
        ),
        isA<NotUpdatable>(),
      );
      expect(
        classify(
          HostOs.macos,
          '/private/var/folders/x/AppTranslocation/1/d/Floresta.app/Contents/MacOS/Floresta',
        ),
        isA<NotUpdatable>(),
      );
      expect(
        classify(
          HostOs.macos,
          '/Applications/Floresta.app/Contents/MacOS/Floresta',
          writable: false,
        ),
        isA<NotUpdatable>(),
      );
    });

    test('Linux: .deb under /opt goes through the system installer', () {
      expect(
        classify(HostOs.linux, '/opt/floresta-gui/floresta_gui'),
        const SystemPackage(),
      );
      expect(
        classify(HostOs.linux, '/home/a/Apps/floresta-gui/floresta_gui'),
        const SelfUpdatable(
          AppPackageFormat.linuxTarGz,
          '/home/a/Apps/floresta-gui',
          executable: '/home/a/Apps/floresta-gui/floresta_gui',
        ),
      );
    });

    test('development builds never update themselves', () {
      expect(
        classify(
          HostOs.macos,
          '/Applications/Floresta.app/Contents/MacOS/Floresta',
          release: false,
        ),
        isA<NotUpdatable>(),
      );
    });
  });

  group('AppUpdater', () {
    late LocalArtifactServer server;
    late TestReleaseKey key;
    late Directory root;
    late Directory apps;

    setUp(() async {
      server = LocalArtifactServer();
      await server.start();
      key = TestReleaseKey.generate();
      root = Directory.systemTemp.createTempSync('app_upd_');
      apps = Directory('${root.path}/Apps')..createSync();
    });
    tearDown(() async {
      await server.stop();
      root.deleteSync(recursive: true);
    });

    AppUpdater updater({HostOs os = HostOs.linux}) => AppUpdater(
      paths: AppPaths(Directory('${root.path}/data')),
      source: ReleaseSource(
        manifestUrl: server.base.resolve('florestad/manifest.json'),
        trustedKeys: [key.trusted],
      ),
      platform: HostPlatform(os, CpuArch.arm64),
    );

    /// A Linux bundle tarball whose VERSION file says [says].
    Future<List<int>> tarball(String says) async {
      final src = Directory('${root.path}/src-$says/floresta-gui')
        ..createSync(recursive: true);
      File('${src.path}/floresta_gui').writeAsStringSync('#!/bin/sh\n');
      File('${src.path}/VERSION').writeAsStringSync('$says\n');
      final out = '${root.path}/pkg-$says.tar.gz';
      final r = await Process.run('tar', [
        '-czf',
        out,
        '-C',
        src.parent.path,
        'floresta-gui',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return File(out).readAsBytesSync();
    }

    void publish(List<int> pkg, {String version = '0.0.2', int serial = 1}) {
      server.files['/app/pkg.tar.gz'] = pkg;
      server.files['/app/manifest.json'] = key.envelope(
        _payload(
          version: version,
          serial: serial,
          artifacts: [
            {
              'os': 'linux',
              'arch': 'arm64',
              'format': 'linux-tar-gz',
              'url': 'pkg.tar.gz',
              'sha256': _sha(pkg),
              'size': pkg.length,
            },
          ],
        ),
      );
    }

    SelfUpdatable installed() {
      final bundle = Directory('${apps.path}/floresta-gui')..createSync();
      File('${bundle.path}/floresta_gui').writeAsStringSync('old');
      return SelfUpdatable(
        AppPackageFormat.linuxTarGz,
        bundle.path,
        executable: '${bundle.path}/floresta_gui',
      );
    }

    test(
      'offers a newer, signed version and nothing for the same one',
      () async {
        publish(await tarball('0.0.2'));
        final kind = installed();
        final offer = (await updater().check(
          current: const AppVersion(0, 0, 1),
          kind: kind,
        )).getOrElse((f) => fail(f.message));
        expect(offer?.version, const AppVersion(0, 0, 2));
        expect(offer?.artifact?.format, AppPackageFormat.linuxTarGz);
        final none = await updater().check(
          current: const AppVersion(0, 0, 2),
          kind: kind,
        );
        expect(none.getOrElse((f) => fail(f.message)), isNull);
      },
    );

    test('an older serial than one already seen is refused', () async {
      publish(await tarball('0.0.2'), serial: 5);
      final kind = installed();
      await updater().check(current: const AppVersion(0, 0, 1), kind: kind);
      publish(await tarball('0.0.2'), serial: 4);
      final r = await updater().check(
        current: const AppVersion(0, 0, 1),
        kind: kind,
      );
      expect(r.getLeft().toNullable()?.message, contains('older update'));
    });

    test('an unsigned or wrongly signed manifest is refused', () async {
      publish(await tarball('0.0.2'));
      final stranger = TestReleaseKey.generate(id: 'test-key');
      server.files['/app/manifest.json'] = stranger.envelope(_payload());
      final r = await updater().check(
        current: const AppVersion(0, 0, 1),
        kind: installed(),
      );
      expect(r.getLeft().toNullable(), isA<InstallationFailure>());
    });

    test('downloads, verifies and unpacks next to the installed app', () async {
      publish(await tarball('0.0.2'));
      final kind = installed();
      final u = updater();
      final offer = (await u.check(
        current: const AppVersion(0, 0, 1),
        kind: kind,
      )).getOrElse((f) => fail(f.message))!;
      final staged = (await u.download(
        offer,
      )).getOrElse((f) => fail(f.message));
      expect(staged.path, startsWith('${apps.path}/.floresta-update-0.0.2/'));
      expect(File('${staged.path}/VERSION').readAsStringSync().trim(), '0.0.2');
      // The installed app is untouched until the swap.
      expect(File(kind.executable).readAsStringSync(), 'old');
    });

    test('a package that says another version is refused', () async {
      publish(await tarball('0.0.9'));
      final u = updater();
      final offer = (await u.check(
        current: const AppVersion(0, 0, 1),
        kind: installed(),
      )).getOrElse((f) => fail(f.message))!;
      final r = await u.download(offer);
      expect(r.getLeft().toNullable()?.message, contains('0.0.9'));
      expect(
        Directory('${apps.path}/.floresta-update-0.0.2').existsSync(),
        isFalse,
      );
    });

    test('a package whose hash differs is refused before unpacking', () async {
      publish(await tarball('0.0.2'));
      final u = updater();
      final offer = (await u.check(
        current: const AppVersion(0, 0, 1),
        kind: installed(),
      )).getOrElse((f) => fail(f.message))!;
      server.files['/app/pkg.tar.gz'] = await tarball('0.0.2-tampered');
      final r = await u.download(offer);
      expect(r.isLeft(), isTrue);
      expect(
        Directory('${apps.path}/.floresta-update-0.0.2').existsSync(),
        isFalse,
      );
    });
  });

  group('swap helper (real /bin/sh)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('swap_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<int> exitedPid() async {
      final p = await Process.start('/bin/sh', ['-c', 'exit 0']);
      await p.exitCode;
      return p.pid;
    }

    Future<Map<String, Object?>> run({
      required String target,
      required String newBundle,
    }) async {
      final script = File('${dir.path}/swap.sh')
        ..writeAsStringSync(AppUpdater.swapScript);
      final result = '${dir.path}/result.json';
      final r = await Process.run('/bin/sh', [
        script.path,
        '${await exitedPid()}',
        newBundle,
        target,
        '$target/run',
        '${dir.path}/no-relaunch',
        result,
        '0.0.2',
        'linux',
        '${dir.path}/pending',
      ]);
      expect(File(result).existsSync(), isTrue, reason: '${r.stderr}');
      return jsonDecode(File(result).readAsStringSync())
          as Map<String, Object?>;
    }

    test('replaces the bundle and keeps the old one aside', () async {
      final apps = Directory('${dir.path}/Apps')..createSync();
      final target = Directory('${apps.path}/floresta-gui')..createSync();
      File('${target.path}/v').writeAsStringSync('old');
      final staged = Directory('${apps.path}/.floresta-update-0.0.2/b')
        ..createSync(recursive: true);
      File('${staged.path}/v').writeAsStringSync('new');
      final r = await run(target: target.path, newBundle: staged.path);
      expect(r['ok'], isTrue);
      expect(File('${target.path}/v').readAsStringSync(), 'new');
      expect(
        File(
          '${apps.path}/.floresta-previous-floresta-gui/v',
        ).readAsStringSync(),
        'old',
      );
      expect(
        Directory('${apps.path}/.floresta-update-0.0.2').existsSync(),
        isFalse,
      );
    });

    test('a missing new version leaves the installed app in place', () async {
      final target = Directory('${dir.path}/floresta-gui')..createSync();
      File('${target.path}/v').writeAsStringSync('old');
      final r = await run(
        target: target.path,
        newBundle: '${dir.path}/.floresta-update-0.0.2/missing',
      );
      expect(r['ok'], isFalse);
      expect(File('${target.path}/v').readAsStringSync(), 'old');
    });
  });
}
