/// Opt-in end-to-end test of the real installer with a REAL florestad
/// artifact, as a user would get it, minus public hosting:
///
///   tool/release/build_florestad_artifact.sh aarch64-apple-darwin DIR
///   FLORESTA_ARTIFACT_DIR=DIR flutter test test/integration/artifact_install_regtest_test.dart
///
/// The artifact directory holds `florestad-v*-OS-ARCH` plus its
/// `.build-info.json`. The test signs a schema-2 manifest with a key created
/// at runtime, serves it from 127.0.0.1, installs through `ManagedInstaller`
/// into a temp app-data root, then starts the INSTALLED binary on regtest,
/// waits for RPC and stops it with the `stop` RPC. Isolation as in
/// florestad_regtest_test.dart: temp data dir, loopback ports, one dead peer.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/installation/data/artifact_downloader.dart';
import 'package:floresta_gui/features/installation/data/managed_install_store.dart';
import 'package:floresta_gui/features/installation/data/managed_installer.dart';
import 'package:floresta_gui/features/installation/data/release_source.dart';
import 'package:floresta_gui/features/installation/data/release_trust_store.dart';
import 'package:floresta_gui/features/installation/data/version_probe.dart';
import 'package:floresta_gui/features/installation/domain/installer.dart';
import 'package:floresta_gui/features/installation/domain/release_manifest.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../helpers/local_artifact_server.dart';

final _artifactDir = Platform.environment['FLORESTA_ARTIFACT_DIR'];

Future<int> _freeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
    'installs a real signed artifact, then runs it on regtest',
    () async {
      final platform = HostPlatform.current();
      final dir = Directory(_artifactDir!);
      final info = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.build-info.json'))
          .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>)
          .where(
            (i) =>
                i['os'] == platform.os.name && i['arch'] == platform.arch.name,
          )
          .firstOrNull;
      if (info == null) {
        fail('no artifact for ${platform.label} in ${dir.path}');
      }
      final name = info['artifact']! as String;
      final bytes = File('${dir.path}/$name').readAsBytesSync();

      // 1. Publish on loopback with a runtime-only key.
      final key = TestReleaseKey.generate(id: ReleaseSource.developmentKeyId);
      final server = LocalArtifactServer();
      await server.start();
      addTearDown(server.stop);
      final now = DateTime.now().toUtc();
      server.files['/$name'] = bytes;
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
            'size': bytes.length,
          },
        ],
      });

      // 2. Install through the app's installer into a temp app-data root.
      final root = await Directory.systemTemp.createTemp(
        'floresta_install_it_',
      );
      addTearDown(() async {
        if (root.path.contains('floresta_install_it_') && root.existsSync()) {
          await root.delete(recursive: true);
        }
      });
      final paths = AppPaths(root);
      final source = ReleaseSource.resolve(
        manifestUrl: '${server.base.resolve('manifest.json')}',
        devKeyHex: key.trusted.publicKeyHex,
      )!;
      final states = await ManagedInstaller(
        paths: paths,
        source: source,
        downloader: ArtifactDownloader(),
        probe: VersionProbe(),
        store: ManagedInstallStore(paths),
        trust: ReleaseTrustStore(paths),
      ).install(platform).toList();
      final done = states.last;
      if (done is! InstallCompleted) fail('install failed: $done');
      final exe = done.executablePath;
      expect(exe, startsWith(paths.versions.path));

      // 3. Run the installed binary on an isolated regtest node.
      final dataDir = await Directory.systemTemp.createTemp('floresta_it_');
      addTearDown(() async {
        if (dataDir.path.contains('floresta_it_') && dataDir.existsSync()) {
          await dataDir.delete(recursive: true);
        }
      });
      final electrumPort = await _freeLoopbackPort();
      final deadPeerPort = await _freeLoopbackPort();
      final settings = NodeSettings(
        network: BitcoinNetwork.regtest,
        dataDir: dataDir.path,
        rpcPort: await _freeLoopbackPort(),
        logToFile: false,
      );
      final httpClient = http.Client();
      addTearDown(httpClient.close);
      final rpc = NodeRpcRepositoryImpl(
        JsonRpcClient(
          endpoint: settings.rpcEndpoint,
          httpClient: httpClient,
          defaultTimeout: const Duration(seconds: 5),
        ),
      );
      final manager = FlorestadProcessManager(
        startProcess: (exe, args) => Process.start(exe, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrumPort',
          '--connect',
          '127.0.0.1:$deadPeerPort',
          '--disable-dns-seeds',
        ]),
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
      );
      addTearDown(manager.dispose);
      expect(
        (await manager.start(
          executablePath: exe,
          settings: settings,
        )).isRight(),
        isTrue,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      BlockchainInfo? chain;
      while (chain == null) {
        if (!manager.state.isActive) fail('exited: ${manager.state}');
        if (DateTime.now().isAfter(deadline)) fail('RPC not ready in 60 s');
        chain = (await rpc.getBlockchainInfo()).toNullable();
        if (chain == null) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      expect(chain.network, BitcoinNetwork.regtest);
      expect((await manager.stop()).isRight(), isTrue);
      expect(manager.state, const ProcessStopped(0));
    },
    skip: _artifactDir == null
        ? 'Set FLORESTA_ARTIFACT_DIR to a built artifact directory'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
