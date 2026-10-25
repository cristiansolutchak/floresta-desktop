/// Opt-in lifecycle test against a REAL florestad binary on regtest.
///
/// Skipped unless `FLORESTAD_PATH` points at a florestad executable:
///
///   FLORESTAD_PATH=/path/to/florestad flutter test test/integration
///
/// It exercises the app's own integration code (FlorestadProcessManager,
/// JsonRpcClient, NodeRpcRepositoryImpl) — nothing here is mocked. The node
/// runs in a fresh temp data dir on free loopback ports. v0.9.1 hard-codes
/// `127.0.0.1:18444` (Bitcoin Core's regtest P2P port) as a regtest seed, so
/// the node is pinned with `--connect` to a closed loopback port: it cannot
/// reach a developer's bitcoind, any other node, or the internet.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/installation/data/version_probe.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _florestad = Platform.environment['FLORESTAD_PATH'];

/// Regtest genesis block hash (identical for every regtest chain).
const _regtestGenesis =
    '0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206';

const _startupTimeout = Duration(seconds: 60);
const _pollInterval = Duration(milliseconds: 250);

Future<int> _freeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
    'florestad starts on regtest, reports status and stops cleanly',
    () async {
      final exe = _florestad!;

      // 1. Binary sanity check through the app's own probe.
      final version = (await VersionProbe().probe(
        exe,
      )).match((f) => fail('version probe failed: ${f.message}'), (v) => v);
      expect(version.isSupported, isTrue, reason: 'got $version');

      // 2. Isolated environment.
      final dataDir = await Directory.systemTemp.createTemp('floresta_it_');
      addTearDown(() async {
        // Only ever delete the directory this test created.
        if (dataDir.path.contains('floresta_it_') && dataDir.existsSync()) {
          await dataDir.delete(recursive: true);
        }
      });
      final rpcPort = await _freeLoopbackPort();
      final electrumPort = await _freeLoopbackPort();
      // Nothing listens here; `--connect` makes it the only peer florestad
      // will try (crates/floresta-wire/src/p2p_wire/node/conn.rs).
      final deadPeerPort = await _freeLoopbackPort();
      final settings = NodeSettings(
        network: BitcoinNetwork.regtest,
        dataDir: dataDir.path,
        rpcPort: rpcPort,
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

      var gracefulAccepted = false;
      final manager = FlorestadProcessManager(
        // The production starter, plus isolation-only flags the app does not
        // set (Electrum port, a single unreachable peer, no DNS seeds).
        startProcess: (exe, args) => Process.start(exe, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrumPort',
          '--connect',
          '127.0.0.1:$deadPeerPort',
          '--disable-dns-seeds',
        ]),
        requestGracefulStop: () async {
          gracefulAccepted = (await rpc.requestStop()).isRight();
          return gracefulAccepted;
        },
      );
      // Runs even if an assertion fails: escalates to SIGKILL if needed.
      addTearDown(manager.dispose);
      addTearDown(
        () => printOnFailure(
          '--- florestad output ---\n'
          '${manager.logs.map((l) => '[${l.source.name}] ${l.text}').join('\n')}',
        ),
      );

      // 3. Start the real process.
      final started = await manager.start(
        executablePath: exe,
        settings: settings,
      );
      expect(started.isRight(), isTrue, reason: '$started');
      expect(manager.state, isA<ProcessRunning>());

      // 4. Poll readiness with a bounded timeout; fail fast on a crash.
      final deadline = DateTime.now().add(_startupTimeout);
      final stopwatch = Stopwatch()..start();
      BlockchainInfo? info;
      while (info == null) {
        if (!manager.state.isActive) {
          fail('florestad exited during startup: ${manager.state}');
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('RPC not ready within ${_startupTimeout.inSeconds}s');
        }
        info = (await rpc.getBlockchainInfo()).toNullable();
        if (info == null) await Future<void>.delayed(_pollInterval);
      }
      final readyAfter = stopwatch.elapsed;

      // 5–6. Status consistent with a fresh, peerless regtest node.
      expect(info.network, BitcoinNetwork.regtest);
      expect(info.bestBlockHash, _regtestGenesis);
      expect(info.headerHeight, 0);
      expect(info.validatedHeight, 0);
      expect((await rpc.getPeers()).toNullable(), isEmpty);
      final uptime = (await rpc.getUptime()).toNullable();
      expect(uptime, isNotNull);

      // 7–8. Supported shutdown: `stop` RPC, then wait for process exit.
      stopwatch.reset();
      final stopped = await manager.stop();
      final stopAfter = stopwatch.elapsed;
      expect(stopped.isRight(), isTrue, reason: '$stopped');
      expect(gracefulAccepted, isTrue, reason: 'stop RPC was not accepted');
      expect(manager.state, const ProcessStopped(0));
      expect(
        manager.logs.any((l) => l.text.contains('SIGINT')),
        isFalse,
        reason: 'shutdown needed signal escalation',
      );
      // The API must be gone once the process has exited.
      expect((await rpc.getBlockchainInfo()).isLeft(), isTrue);

      // ignore: avoid_print
      print(
        'florestad $version: RPC ready after ${readyAfter.inMilliseconds} ms, '
        'graceful stop took ${stopAfter.inMilliseconds} ms',
      );
    },
    skip: _florestad == null
        ? 'Set FLORESTAD_PATH to a florestad binary to run this test'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
