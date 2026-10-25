@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/security/file_hash.dart';
import 'package:floresta_gui/features/installation/data/artifact_downloader.dart';
import 'package:floresta_gui/features/installation/data/executable_locator.dart';
import 'package:floresta_gui/features/installation/data/installation_repository_impl.dart';
import 'package:floresta_gui/features/installation/data/managed_install_store.dart';
import 'package:floresta_gui/features/installation/data/managed_installer.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/data/release_trust_store.dart';
import 'package:floresta_gui/features/installation/data/signed_manifest.dart';
import 'package:floresta_gui/features/installation/data/version_probe.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/installer.dart';
import 'package:floresta_gui/features/installation/domain/release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/local_artifact_server.dart';

const _platform = HostPlatform(HostOs.macos, CpuArch.arm64);
const _commit = 'bc2db8d07e72651f9981ce589c5688f4d575dc7a';

List<int> _hex(String h) => BytesUtils.fromHexString(h);

/// A stand-in executable that prints what florestad prints for --version.
List<int> _fakeFlorestad(String version) =>
    utf8.encode('#!/bin/sh\necho "florestad v$version"\n');

String _sha(List<int> bytes) =>
    BytesUtils.toHexString(QuickCrypto.sha256Hash(bytes));

Map<String, Object?> _manifest({
  String version = '0.9.1',
  required List<int> artifact,
  String url = 'florestad-macos-arm64',
  String os = 'macos',
  String arch = 'arm64',
  int serial = 1,
}) => {
  'type': ReleaseManifest.type,
  'schema': 2,
  'serial': serial,
  'issued': '2026-01-01T00:00:00Z',
  'expires': '2100-01-01T00:00:00Z',
  'version': version,
  'upstreamTag': 'v$version',
  'upstreamCommit': _commit,
  'artifacts': [
    {
      'os': os,
      'arch': arch,
      'url': url,
      'sha256': _sha(artifact),
      'size': artifact.length,
    },
  ],
};

void main() {
  group('Ed25519 (blockchain_utils) against RFC 8032 / OpenSSL 3.6.1', () {
    // RFC 8032 §7.1 tests 1–3. Tests 2 and 3 were also reproduced with
    // OpenSSL 3.6.1 from the same seeds (public keys and signatures match).
    final vectors = [
      (
        seed:
            '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
        pub: 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        msg: '',
        sig:
            'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
            '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      ),
      (
        seed:
            '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
        pub: '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        msg: '72',
        sig:
            '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
            '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      ),
      (
        seed:
            'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
        pub: 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        msg: 'af82',
        sig:
            '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac'
            '18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
      ),
    ];

    test('verifies the reference signatures', () {
      for (final v in vectors) {
        expect(
          SignedManifestVerifier.verifySignature(
            publicKey: _hex(v.pub),
            message: _hex(v.msg),
            signature: _hex(v.sig),
          ),
          isTrue,
          reason: v.pub,
        );
      }
    });

    test('signer and key derivation reproduce the reference values', () {
      for (final v in vectors) {
        expect(
          BytesUtils.toHexString(
            Ed25519Signer.fromKeyBytes(_hex(v.seed)).sign(_hex(v.msg)),
          ),
          v.sig,
        );
        expect(
          BytesUtils.toHexString(
            Ed25519PrivateKey.fromBytes(
              _hex(v.seed),
            ).publicKey.compressed.sublist(1),
          ),
          v.pub,
        );
      }
    });

    test('rejects modified messages, signatures, keys and bad lengths', () {
      final v = vectors[1];
      final sig = _hex(v.sig);
      bool check(List<int> pub, List<int> msg, List<int> s) =>
          SignedManifestVerifier.verifySignature(
            publicKey: pub,
            message: msg,
            signature: s,
          );
      expect(check(_hex(v.pub), _hex('73'), sig), isFalse);
      expect(check(_hex(v.pub), _hex(v.msg), [...sig]..[10] ^= 1), isFalse);
      expect(check(_hex(vectors[0].pub), _hex(v.msg), sig), isFalse);
      expect(check(_hex(v.pub).sublist(1), _hex(v.msg), sig), isFalse);
      expect(check(_hex(v.pub), _hex(v.msg), sig.sublist(1)), isFalse);
      expect(check(List.filled(32, 0xff), _hex(v.msg), sig), isFalse);
    });
  });

  group('SignedManifestVerifier', () {
    final key = TestReleaseKey.generate();
    final verifier = SignedManifestVerifier([key.trusted]);
    final base = Uri.parse('https://releases.example/floresta/manifest.json');
    final artifact = _fakeFlorestad('0.9.1');

    test('accepts a correctly signed manifest and resolves relative URLs', () {
      final m = verifier
          .verify(key.envelope(_manifest(artifact: artifact)), base)
          .toNullable()!;
      expect('${m.version}', 'v0.9.1');
      final a = m.artifactFor(_platform).toNullable()!;
      expect(
        a.url,
        Uri.parse('https://releases.example/floresta/florestad-macos-arm64'),
      );
      expect(a.size, artifact.length);
    });

    test('rejects unknown keys, bad signatures and tampered payloads', () {
      final other = TestReleaseKey.generate(id: 'other');
      expect(
        verifier
            .verify(other.envelope(_manifest(artifact: artifact)), base)
            .getLeft()
            .toNullable()
            ?.message,
        contains('unknown key'),
      );
      // Signed by another key but claiming the trusted id.
      expect(
        verifier
            .verify(
              other.envelope(_manifest(artifact: artifact), keyId: key.id),
              base,
            )
            .isLeft(),
        isTrue,
      );
      final env =
          jsonDecode(utf8.decode(key.envelope(_manifest(artifact: artifact))))
              as Map;
      final payload =
          jsonDecode(utf8.decode(base64.decode(env['payload'] as String)))
              as Map;
      payload['version'] = '9.9.9';
      env['payload'] = base64.encode(utf8.encode(jsonEncode(payload)));
      expect(
        verifier
            .verify(utf8.encode(jsonEncode(env)), base)
            .getLeft()
            .toNullable()
            ?.message,
        contains('signature'),
      );
      expect(verifier.verify(utf8.encode('not json'), base).isLeft(), isTrue);
    });

    test('rejects malformed but correctly signed content', () {
      Map<String, Object?> m() => _manifest(artifact: artifact);
      expect(
        verifier.verify(key.envelope({...m(), 'schema': 1}), base).isLeft(),
        isTrue,
      );
      expect(
        verifier
            .verify(key.envelope({...m(), 'upstreamCommit': 'xyz'}), base)
            .isLeft(),
        isTrue,
      );
      final bad = m();
      ((bad['artifacts'] as List).first as Map)['sha256'] = 'zz';
      expect(verifier.verify(key.envelope(bad), base).isLeft(), isTrue);
    });

    test('reports platforms without a published artifact', () {
      final m = verifier
          .verify(
            key.envelope(
              _manifest(artifact: artifact, os: 'linux', arch: 'x64'),
            ),
            base,
          )
          .toNullable()!;
      expect(
        m.artifactFor(_platform).getLeft().toNullable(),
        isA<InstallationFailure>(),
      );
    });

    test('ships no production keys until signing ownership is decided', () {
      expect(productionReleaseKeys, isEmpty);
    });
  });

  group('AppPaths', () {
    test('uses per-OS user locations and the test override', () {
      expect(
        AppPaths.forPlatform(_platform, const {'HOME': '/Users/a'}).root.path,
        '/Users/a/Library/Application Support/io.github.cristiansolutchak.florestaGui',
      );
      expect(
        AppPaths.forPlatform(
          const HostPlatform(HostOs.linux, CpuArch.x64),
          const {'HOME': '/home/a'},
        ).root.path,
        '/home/a/.local/share/floresta-gui',
      );
      expect(
        AppPaths.forPlatform(
          const HostPlatform(HostOs.linux, CpuArch.x64),
          const {'HOME': '/home/a', 'XDG_DATA_HOME': '/data'},
        ).root.path,
        '/data/floresta-gui',
      );
      expect(
        AppPaths.forPlatform(_platform, const {
          'FLORESTA_GUI_DATA_ROOT': '/tmp/x',
          'HOME': '/u',
        }).root.path,
        '/tmp/x',
      );
    });
  });

  group('ArtifactDownloader', () {
    late LocalArtifactServer server;
    late Directory dir;
    final body = List<int>.generate(300000, (i) => i % 251);
    late ReleaseArtifact artifact;
    final downloader = ArtifactDownloader(
      retryDelay: Duration.zero,
      idleTimeout: const Duration(seconds: 5),
    );

    setUp(() async {
      server = LocalArtifactServer();
      await server.start();
      server.files['/a.bin'] = body;
      dir = Directory.systemTemp.createTempSync('dl_');
      artifact = ReleaseArtifact(
        os: HostOs.macos,
        arch: CpuArch.arm64,
        url: server.base.resolve('a.bin'),
        sha256: _sha(body),
        size: body.length,
      );
    });
    tearDown(() async {
      await server.stop();
      dir.deleteSync(recursive: true);
    });

    test('downloads and verifies', () async {
      final progress = <double>[];
      final f = (await downloader.download(
        artifact,
        dir,
        onProgress: (g, t) => progress.add(g / t),
      )).toNullable()!;
      expect(await f.readAsBytes(), body);
      expect(progress.last, 1.0);
    });

    test('resumes with a Range request after the connection drops', () async {
      server.dropAfterBytes = 100000;
      server.dropTimes = 1;
      final f = (await downloader.download(artifact, dir)).toNullable()!;
      expect(await sha256OfFile(f.path), artifact.sha256);
      expect(server.requests, hasLength(2));
      expect(server.requests[1].range, startsWith('bytes='));
      expect(server.requests[1].range, isNot('bytes=0-'));
    });

    test('restarts cleanly when the server ignores Range', () async {
      server.honourRange = false;
      server.dropAfterBytes = 50000;
      server.dropTimes = 1;
      final f = (await downloader.download(artifact, dir)).toNullable()!;
      expect(await f.readAsBytes(), body);
    });

    test('retries server errors, then succeeds', () async {
      server.failStatus = 503;
      server.failTimes = 2;
      expect((await downloader.download(artifact, dir)).isRight(), isTrue);
      expect(server.requests, hasLength(3));
    });

    test('does not retry 404', () async {
      final missing = ReleaseArtifact(
        os: HostOs.macos,
        arch: CpuArch.arm64,
        url: server.base.resolve('missing'),
        sha256: artifact.sha256,
        size: artifact.size,
      );
      expect((await downloader.download(missing, dir)).isLeft(), isTrue);
      expect(server.requests, hasLength(1));
    });

    test('rejects a wrong checksum and deletes the partial file', () async {
      final wrong = ReleaseArtifact(
        os: HostOs.macos,
        arch: CpuArch.arm64,
        url: artifact.url,
        sha256: '00' * 32,
        size: artifact.size,
      );
      final r = await downloader.download(wrong, dir);
      expect(
        (r.getLeft().toNullable()! as InstallationFailure).stage,
        'verify',
      );
      expect(downloader.partFile(dir, wrong).existsSync(), isFalse);
    });

    test('aborts a body larger than announced', () async {
      final small = ReleaseArtifact(
        os: HostOs.macos,
        arch: CpuArch.arm64,
        url: artifact.url,
        sha256: artifact.sha256,
        size: 1000,
      );
      final r = await downloader.download(small, dir);
      expect(r.getLeft().toNullable()?.message, contains('larger'));
      expect(server.requests, hasLength(1));
    });

    test('refuses non-HTTPS URLs except loopback', () async {
      final insecure = ReleaseArtifact(
        os: HostOs.macos,
        arch: CpuArch.arm64,
        url: Uri.parse('http://example.com/a.bin'),
        sha256: artifact.sha256,
        size: artifact.size,
      );
      expect((await downloader.download(insecure, dir)).isLeft(), isTrue);
      expect(server.requests, isEmpty);
    });

    test('cancellation keeps the partial file for resume', () async {
      final cancel = CancelToken();
      final r = await downloader.download(
        artifact,
        dir,
        cancel: cancel,
        onProgress: (g, _) {
          if (g > 1000) cancel.cancel();
        },
      );
      expect(r.getLeft().toNullable()?.message, contains('cancelled'));
      expect(downloader.partFile(dir, artifact).existsSync(), isTrue);
    });
  });

  group('ManagedInstaller', () {
    late LocalArtifactServer server;
    late Directory root;
    late AppPaths paths;
    late TestReleaseKey key;
    late ManagedInstallStore store;

    ReleaseSource source() => ReleaseSource(
      manifestUrl: server.base.resolve('manifest.json'),
      trustedKeys: [key.trusted],
    );

    ManagedInstaller installer({ArtifactDownloader? downloader}) =>
        ManagedInstaller(
          paths: paths,
          source: source(),
          downloader:
              downloader ?? ArtifactDownloader(retryDelay: Duration.zero),
          probe: VersionProbe(),
          store: store,
          trust: ReleaseTrustStore(paths),
        );

    var serial = 0;
    void publish(String version, {String? reports}) {
      final bin = _fakeFlorestad(reports ?? version);
      server.files['/florestad-$version'] = bin;
      server.files['/manifest.json'] = key.envelope(
        _manifest(
          version: version,
          artifact: bin,
          url: 'florestad-$version',
          serial: ++serial,
        ),
      );
    }

    setUp(() async {
      server = LocalArtifactServer();
      await server.start();
      root = Directory.systemTemp.createTempSync('mi_');
      paths = AppPaths(root);
      key = TestReleaseKey.generate();
      store = ManagedInstallStore(paths);
    });
    tearDown(() async {
      await server.stop();
      root.deleteSync(recursive: true);
    });

    test('installs, records and runs the verified binary', () async {
      publish('0.9.1');
      final states = await installer().install(_platform).toList();
      expect(states.first, isA<InstallResolving>());
      expect(states.whereType<InstallVerifying>(), hasLength(1));
      expect(states.whereType<InstallInstalling>(), hasLength(1));
      final done = states.last as InstallCompleted;
      expect(done.executablePath, startsWith(paths.versionDir('0.9.1').path));
      final record = (await store.read()).toNullable()!;
      expect(record.version, '0.9.1');
      expect(await store.isIntact(record), isTrue);
      expect(
        (await VersionProbe().probe(done.executablePath)).isRight(),
        isTrue,
      );
      expect(paths.staging.listSync().whereType<Directory>(), isEmpty);
    });

    test('does not reinstall an intact current version', () async {
      publish('0.9.1');
      await installer().install(_platform).toList();
      server.requests.clear();
      final states = await installer().install(_platform).toList();
      expect(states.last, isA<InstallCompleted>());
      expect(server.requests.map((r) => r.path), ['/manifest.json']);
    });

    test(
      'upgrades, keeps the previous version and prunes older ones',
      () async {
        publish('0.9.0');
        await installer().install(_platform).toList();
        publish('0.9.1');
        await installer().install(_platform).toList();
        publish('0.9.2');
        await installer().install(_platform).toList();
        final record = (await store.read()).toNullable()!;
        expect(record.version, '0.9.2');
        expect(record.previous?.version, '0.9.1');
        final dirs = paths.versions
            .listSync()
            .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
            .toSet();
        expect(dirs, {'0.9.1', '0.9.2'});
      },
    );

    test(
      'refuses a binary whose --version differs from the manifest',
      () async {
        publish('0.9.0');
        await installer().install(_platform).toList();
        publish('0.9.1', reports: '0.9.0');
        final states = await installer().install(_platform).toList();
        expect(
          (states.last as InstallFailed).reason,
          contains('expected v0.9.1'),
        );
        expect(
          (await store.read()).toNullable()!.version,
          '0.9.0',
          reason: 'previous install untouched',
        );
      },
    );

    test('nothing is installed when the manifest signature is wrong', () async {
      publish('0.9.1');
      server.files['/manifest.json'] = TestReleaseKey.generate(id: key.id)
          .envelope(
            _manifest(
              artifact: _fakeFlorestad('0.9.1'),
              url: 'florestad-0.9.1',
              serial: 99,
            ),
          );
      final states = await installer().install(_platform).toList();
      expect(states.last, isA<InstallFailed>());
      expect((await store.read()).toNullable(), isNull);
      expect(server.requests.where((r) => r.path != '/manifest.json'), isEmpty);
    });

    test(
      'refuses a replayed older manifest and remembers the serial',
      () async {
        publish('0.9.0'); // serial n
        final old = server.files['/manifest.json']!;
        publish('0.9.1'); // serial n + 1
        expect(
          (await installer().install(_platform).toList()).last,
          isA<InstallCompleted>(),
        );
        server.files['/manifest.json'] = old;
        final states = await installer().install(_platform).toList();
        expect((states.last as InstallFailed).reason, contains('older'));
        expect((await store.read()).toNullable()!.version, '0.9.1');
        final trust = (await ReleaseTrustStore(paths).read()).toNullable()!;
        expect(trust.highestSerial, serial);
      },
    );

    test('refuses an expired manifest', () async {
      final bin = _fakeFlorestad('0.9.1');
      server.files['/florestad-0.9.1'] = bin;
      server.files['/manifest.json'] = key.envelope({
        ..._manifest(artifact: bin, url: 'florestad-0.9.1'),
        'expires': '2026-02-01T00:00:00Z',
      });
      final states = await installer().install(_platform).toList();
      expect((states.last as InstallFailed).reason, contains('expired'));
      expect(server.requests.where((r) => r.path != '/manifest.json'), isEmpty);
    });

    test('a revoked key is refused afterwards', () async {
      final bin = _fakeFlorestad('0.9.1');
      server.files['/florestad-0.9.1'] = bin;
      server.files['/manifest.json'] = key.envelope({
        ..._manifest(artifact: bin, url: 'florestad-0.9.1', serial: 50),
        'revokedKeys': ['old-key'],
      });
      expect(
        (await installer().install(_platform).toList()).last,
        isA<InstallCompleted>(),
      );
      final oldKey = TestReleaseKey.generate(id: 'old-key');
      final installer2 = ManagedInstaller(
        paths: paths,
        source: ReleaseSource(
          manifestUrl: server.base.resolve('manifest.json'),
          trustedKeys: [key.trusted, oldKey.trusted],
        ),
        downloader: ArtifactDownloader(retryDelay: Duration.zero),
        probe: VersionProbe(),
        store: store,
        trust: ReleaseTrustStore(paths),
      );
      server.files['/manifest.json'] = oldKey.envelope(
        _manifest(artifact: bin, url: 'florestad-0.9.1', serial: 51),
      );
      final states = await installer2.install(_platform).toList();
      expect((states.last as InstallFailed).reason, contains('unknown key'));
    });

    test(
      'follows a same-host redirect for the manifest and artifact',
      () async {
        publish('0.9.1');
        server.redirects['/stable/manifest.json'] = '/manifest.json';
        // Relative artifact URLs resolve against the configured manifest URL.
        server.redirects['/stable/florestad-0.9.1'] = '/blobs/f';
        server.files['/blobs/f'] = server.files['/florestad-0.9.1']!;
        final states = await ManagedInstaller(
          paths: paths,
          source: ReleaseSource(
            manifestUrl: server.base.resolve('stable/manifest.json'),
            trustedKeys: [key.trusted],
          ),
          downloader: ArtifactDownloader(retryDelay: Duration.zero),
          probe: VersionProbe(),
          store: store,
          trust: ReleaseTrustStore(paths),
        ).install(_platform).toList();
        expect(states.last, isA<InstallCompleted>());
        expect(server.requests.map((r) => r.path), contains('/blobs/f'));
      },
    );

    test('recovers from an interrupted install', () async {
      publish('0.9.1');
      Directory('${paths.staging.path}/0.9.1').createSync(recursive: true);
      File('${paths.currentPointer.path}.tmp').writeAsStringSync('{partial');
      final states = await installer().install(_platform).toList();
      expect(states.last, isA<InstallCompleted>());
      expect(File('${paths.currentPointer.path}.tmp').existsSync(), isFalse);
    });

    test(
      'a failed download leaves no record and a resumable part file',
      () async {
        publish('0.9.1');
        server.faultPath = '/florestad-0.9.1';
        server.dropAfterBytes = 5;
        server.dropTimes = 99;
        final states = await installer(
          downloader: ArtifactDownloader(
            retryDelay: Duration.zero,
            maxAttempts: 2,
          ),
        ).install(_platform).toList();
        expect(states.last, isA<InstallFailed>());
        expect((await store.read()).toNullable(), isNull);
        expect(
          paths.staging.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.part'),
          ),
          hasLength(1),
        );
      },
    );
  });

  group('Detection with a managed install', () {
    late Directory root;
    late AppPaths paths;
    late ManagedInstallStore store;
    late Directory pathDir;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('det_');
      paths = AppPaths(Directory('${root.path}/app'));
      store = ManagedInstallStore(paths);
      pathDir = Directory('${root.path}/bin')..createSync();
      final onPath = File('${pathDir.path}/florestad')
        ..writeAsBytesSync(_fakeFlorestad('0.9.0'));
      await Process.run('chmod', ['755', onPath.path]);
    });
    tearDown(() => root.deleteSync(recursive: true));

    InstallationRepositoryImpl repo() => InstallationRepositoryImpl(
      locator: ExecutableLocator(
        platform: _platform,
        environment: {'PATH': pathDir.path},
      ),
      probe: VersionProbe(),
      managed: store,
    );

    Future<String> installManaged(String version) async {
      final dir = paths.versionDir(version)..createSync(recursive: true);
      final bin = File('${dir.path}/florestad')
        ..writeAsBytesSync(_fakeFlorestad(version));
      await Process.run('chmod', ['755', bin.path]);
      await store.write(
        ManagedInstall(
          version: version,
          path: bin.path,
          sha256: await sha256OfFile(bin.path),
        ),
      );
      return bin.path;
    }

    test('falls back to PATH when nothing is managed', () async {
      final r = (await repo().detect()).toNullable()!;
      expect(r.source, ExecutableSource.path);
    });

    test('prefers the managed install over PATH', () async {
      final path = await installManaged('0.9.1');
      final r = (await repo().detect()).toNullable()!;
      expect(r.source, ExecutableSource.managed);
      expect(r.executablePath, path);
      expect('${r.version}', 'v0.9.1');
    });

    test('an explicitly configured path still wins', () async {
      await installManaged('0.9.1');
      final r = (await repo().detect(
        configuredPath: '${pathDir.path}/florestad',
      )).toNullable()!;
      expect(r.source, ExecutableSource.configured);
    });

    test(
      'a modified managed binary is reported, not silently replaced',
      () async {
        final path = await installManaged('0.9.1');
        File(path).writeAsStringSync('#!/bin/sh\necho tampered\n');
        final f = (await repo().detect()).getLeft().toNullable();
        expect(f, isA<ExecutableInvalidFailure>());
        expect(f?.recovery, contains('Reinstall'));
      },
    );
  });
}
