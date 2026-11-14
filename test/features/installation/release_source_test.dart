@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart'
    hide Either, Left, Right;
import 'package:floresta_desktop/core/platform/app_paths.dart';
import 'package:floresta_desktop/core/platform/host_platform.dart';
import 'package:floresta_desktop/features/installation/data/artifact_downloader.dart';
import 'package:floresta_desktop/features/installation/data/release_source.dart';
import 'package:floresta_desktop/features/installation/data/release_trust_store.dart';
import 'package:floresta_desktop/features/installation/data/signed_manifest.dart';
import 'package:floresta_desktop/features/installation/domain/floresta_version.dart';
import 'package:floresta_desktop/features/installation/domain/installation.dart';
import 'package:floresta_desktop/features/installation/domain/release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/local_artifact_server.dart';

void main() {
  final devKey = 'ab' * 32;

  group('ReleaseSource.resolve', () {
    test('no URL or no trusted key means no source', () {
      expect(ReleaseSource.resolve(manifestUrl: ''), isNull);
      expect(
        ReleaseSource.resolve(
          manifestUrl: 'https://r.example/m.json',
          productionKeys: const [],
        ),
        isNull,
        reason: 'a URL alone is never trusted',
      );
    });

    test('a production build never trusts a development key', () {
      expect(
        ReleaseSource.resolve(
          manifestUrl: 'http://127.0.0.1:8080/manifest.json',
          devKeyHex: devKey,
          allowDevKey: false,
          productionKeys: const [],
        ),
        isNull,
      );
    });

    test('refuses insecure manifest URLs', () {
      expect(
        ReleaseSource.resolve(
          manifestUrl: 'http://r.example/m.json',
          productionKeys: const [TrustedReleaseKey(id: 'p', publicKeyHex: '')],
        ),
        isNull,
      );
    });

    test('a development key is trusted only for a loopback manifest', () {
      final local = ReleaseSource.resolve(
        manifestUrl: 'http://127.0.0.1:8080/manifest.json',
        devKeyHex: devKey,
        productionKeys: const [],
      )!;
      expect(local.trustedKeys.single.id, ReleaseSource.developmentKeyId);

      expect(
        ReleaseSource.resolve(
          manifestUrl: 'https://r.example/m.json',
          devKeyHex: devKey,
          productionKeys: const [],
        ),
        isNull,
      );
      final remote = ReleaseSource.resolve(
        manifestUrl: 'https://r.example/m.json',
        devKeyHex: devKey,
        productionKeys: const [TrustedReleaseKey(id: 'p', publicKeyHex: '')],
      )!;
      expect(remote.trustedKeys.map((k) => k.id), ['p']);
    });

    test('ignores a malformed development key', () {
      expect(
        ReleaseSource.resolve(
          manifestUrl: 'http://127.0.0.1:8080/manifest.json',
          devKeyHex: 'xyz',
          productionKeys: const [],
        ),
        isNull,
      );
    });

    test('parses the redirect allowlist', () {
      final s = ReleaseSource.resolve(
        manifestUrl: 'http://localhost:1/m.json',
        devKeyHex: devKey,
        redirectHosts: ' Assets.Example , ,cdn.example',
        productionKeys: const [],
      )!;
      expect(s.redirectHosts, {'assets.example', 'cdn.example'});
    });

    test('this build has no compiled-in source', () {
      expect(ReleaseSource.fromEnvironment(), isNull);
    });
  });

  group('isAllowedRedirect', () {
    final from = Uri.parse('https://a.example/m.json');
    test('same host, or allowlisted https host', () {
      expect(
        isAllowedRedirect(from, Uri.parse('https://a.example/x'), {}),
        isTrue,
      );
      expect(
        isAllowedRedirect(from, Uri.parse('https://b.example/x'), {}),
        isFalse,
      );
      expect(
        isAllowedRedirect(from, Uri.parse('https://b.example/x'), {
          'b.example',
        }),
        isTrue,
      );
    });
    test('never downgrades', () {
      expect(
        isAllowedRedirect(from, Uri.parse('http://a.example/x'), {'a.example'}),
        isFalse,
      );
      expect(
        isAllowedRedirect(from, Uri.parse('http://127.0.0.1/x'), {}),
        isFalse,
      );
      expect(
        isAllowedRedirect(
          Uri.parse('http://127.0.0.1:1/m'),
          Uri.parse('https://evil.example/x'),
          {},
        ),
        isFalse,
      );
    });
  });

  group('ArtifactDownloader redirects', () {
    late LocalArtifactServer server;
    late Directory dir;
    final body = List<int>.generate(1000, (i) => i % 7);
    final downloader = ArtifactDownloader(retryDelay: Duration.zero);

    ReleaseArtifact at(String path) => ReleaseArtifact(
      os: HostOs.macos,
      arch: CpuArch.arm64,
      url: server.base.resolve(path),
      sha256: _sha256(body),
      size: body.length,
    );

    setUp(() async {
      server = LocalArtifactServer();
      await server.start();
      server.files['/blob'] = body;
      dir = Directory.systemTemp.createTempSync('rd_');
    });
    tearDown(() async {
      await server.stop();
      dir.deleteSync(recursive: true);
    });

    test('follows up to three same-host hops', () async {
      server.redirects
        ..['/a'] = '/b'
        ..['/b'] = '/c'
        ..['/c'] = '/blob';
      expect((await downloader.download(at('a'), dir)).isRight(), isTrue);
    });

    test('refuses a fourth hop, without retrying', () async {
      server.redirects
        ..['/a'] = '/b'
        ..['/b'] = '/c'
        ..['/c'] = '/d'
        ..['/d'] = '/blob';
      final r = await downloader.download(at('a'), dir);
      expect(r.getLeft().toNullable()?.message, contains('too many'));
      expect(server.requests.where((q) => q.path == '/a'), hasLength(1));
    });

    test('refuses a redirect to a host not on the allowlist', () async {
      server.redirects['/a'] = 'https://elsewhere.example/blob';
      final r = await downloader.download(at('a'), dir);
      expect(r.getLeft().toNullable()?.message, contains('unsafe redirect'));
    });

    test('resends Range on every hop when resuming', () async {
      server.redirects['/a'] = '/blob';
      final art = at('a');
      downloader.partFile(dir, art).writeAsBytesSync(body.sublist(0, 400));
      expect((await downloader.download(art, dir)).isRight(), isTrue);
      expect(server.requests.map((q) => (q.path, q.range)), [
        ('/a', 'bytes=400-'),
        ('/blob', 'bytes=400-'),
      ]);
    });
  });

  group('ReleaseTrustStore', () {
    late Directory root;
    late ReleaseTrustStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('ts_');
      store = ReleaseTrustStore(AppPaths(root));
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('starts empty, never lowers the serial or un-revokes', () async {
      var t = (await store.read()).toNullable()!;
      expect(t.highestSerial, 0);
      await store.accept(current: t, serial: 5, revokedKeys: {'k1'});
      t = (await store.read()).toNullable()!;
      await store.accept(current: t, serial: 3, revokedKeys: {});
      t = (await store.read()).toNullable()!;
      expect(t.highestSerial, 5);
      expect(t.revokedKeys, {'k1'});
    });

    test('an unreadable record fails closed', () async {
      AppPaths(root).trustRecord
        ..createSync(recursive: true)
        ..writeAsStringSync('{broken');
      expect((await store.read()).isLeft(), isTrue);
    });
  });

  group('ReleaseManifest.checkFreshness', () {
    ReleaseManifest m({int serial = 5}) => ReleaseManifest.parse({
      'type': ReleaseManifest.type,
      'schema': 2,
      'serial': serial,
      'issued': '2026-10-01T00:00:00Z',
      'expires': '2027-10-01T00:00:00Z',
      'version': '0.9.1',
      'upstreamTag': 'v0.9.1',
      'upstreamCommit': 'bc2db8d07e72651f9981ce589c5688f4d575dc7a',
      'artifacts': <Object?>[],
    }, Uri.parse('https://r.example/')).toNullable()!;
    final now = DateTime.utc(2026, 11, 1);

    test('accepts a fresh manifest with an equal or higher serial', () {
      expect(
        m().checkFreshness(now: now, highestAcceptedSerial: 5).isRight(),
        isTrue,
      );
    });
    test('refuses expired, future-dated and rolled-back manifests', () {
      expect(
        m()
            .checkFreshness(
              now: DateTime.utc(2027, 10, 1),
              highestAcceptedSerial: 0,
            )
            .isLeft(),
        isTrue,
      );
      expect(
        m()
            .checkFreshness(
              now: DateTime.utc(2026, 9, 1),
              highestAcceptedSerial: 0,
            )
            .isLeft(),
        isTrue,
      );
      expect(
        m().checkFreshness(now: now, highestAcceptedSerial: 6).isLeft(),
        isTrue,
      );
    });
    test('the type, tag and validity period are part of the schema', () {
      Object? with_(String k, Object? v) => {
        'type': ReleaseManifest.type,
        'schema': 2,
        'serial': 1,
        'issued': '2026-10-01T00:00:00Z',
        'expires': '2027-10-01T00:00:00Z',
        'version': '0.9.1',
        'upstreamTag': 'v0.9.1',
        'upstreamCommit': 'bc2db8d07e72651f9981ce589c5688f4d575dc7a',
        'artifacts': <Object?>[],
        k: v,
      };
      final base = Uri.parse('https://r.example/');
      for (final bad in [
        with_('type', 'something-else'),
        with_('upstreamTag', 'v0.9.0'),
        with_('serial', 0),
        with_('expires', '2026-09-01T00:00:00Z'),
        // A ref must name this version's tag or this exact master commit.
        with_('upstreamRef', 'v0.9.0'),
        with_('upstreamRef', 'master@3a47993595d1d865fb6bea6bce5e9818b5a6bd7e'),
      ]) {
        expect(
          ReleaseManifest.parse(bad, base).isLeft(),
          isTrue,
          reason: '$bad',
        );
      }
      for (final good in [
        with_('upstreamRef', 'v0.9.1'),
        with_('upstreamRef', 'master@bc2db8d07e72651f9981ce589c5688f4d575dc7a'),
        with_('unrelated', 1), // manifests signed before upstreamRef existed
      ]) {
        expect(ReleaseManifest.parse(good, base).isRight(), isTrue);
      }
    });
  });

  group('version label', () {
    const master = FlorestaInstallation(
      executablePath: '/a/florestad',
      source: ExecutableSource.managed,
      version: FlorestaVersion(0, 9, 0),
      upstreamRef: 'master@3a47993595d1d865fb6bea6bce5e9818b5a6bd7e',
    );

    test('a pinned master build shows its commit', () {
      expect(master.versionLabel, 'v0.9.0 (master 3a47993)');
      expect(master.isReleaseBuild, isFalse);
    });

    test('a release or unknown build shows the version only', () {
      const release = FlorestaInstallation(
        executablePath: '/a/florestad',
        source: ExecutableSource.path,
        version: FlorestaVersion(0, 9, 1),
      );
      expect(release.versionLabel, 'v0.9.1');
      expect(release.isReleaseBuild, isTrue);
    });

    test('the install record keeps the ref', () {
      const record = ManagedInstall(
        version: '0.9.0',
        path: '/a/florestad',
        sha256: 'ab',
        upstreamRef: 'master@3a47993595d1d865fb6bea6bce5e9818b5a6bd7e',
        previous: ManagedInstall(
          version: '0.9.1',
          path: '/b',
          sha256: 'cd',
          upstreamRef: 'v0.9.1',
        ),
      );
      expect(ManagedInstall.fromJson(record.toJson()), record);
      // Records written before 2026-11-13 have no ref.
      expect(
        ManagedInstall.fromJson({
          'version': '0.9.1',
          'path': '/b',
          'sha256': 'cd',
        }).upstreamRef,
        isNull,
      );
    });
  });
}

String _sha256(List<int> bytes) =>
    BytesUtils.toHexString(QuickCrypto.sha256Hash(bytes));
