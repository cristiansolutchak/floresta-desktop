/// Opt-in: NODE-02 and NODE-05 against a REAL florestad on regtest.
///
///   FLORESTAD_PATH=/path/to/florestad flutter test test/integration/node_reattach_regtest_test.dart
///
/// Session A starts florestad (as if the app then crashed without stopping
/// it). Session B, a fresh manager with the same app data, finds the node,
/// adopts it, and stops it with the real `stop` RPC. The preflight probe
/// runs on the real machine before and while the node holds its port.
/// Isolation as in florestad_regtest_test.dart.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/processes/process_inspector.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/data/managed_node_store.dart';
import 'package:floresta_gui/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_gui/features/node/data/preflight_probe.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/preflight.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _florestad = Platform.environment['FLORESTAD_PATH'];

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  test(
    'a node left running is adopted by the next session and stopped',
    () async {
      final exe = File(_florestad!).absolute.path;
      final temp = await Directory.systemTemp.createTemp('floresta_it_');
      addTearDown(() async {
        if (temp.path.contains('floresta_it_') && temp.existsSync()) {
          await temp.delete(recursive: true);
        }
      });
      final paths = AppPaths(Directory('${temp.path}/app'));
      final settings = NodeSettings(
        network: BitcoinNetwork.regtest,
        dataDir: '${temp.path}/data',
        rpcPort: await _freePort(),
        logToFile: true,
      );
      final electrumPort = await _freePort();
      final deadPeer = await _freePort();
      final client = http.Client();
      addTearDown(client.close);
      final rpc = NodeRpcRepositoryImpl(
        JsonRpcClient(
          endpoint: settings.rpcEndpoint,
          httpClient: client,
          defaultTimeout: const Duration(seconds: 5),
        ),
      );
      final probe = PreflightProbe(homeDir: temp.path);

      // NODE-05 before start: the real machine is ready.
      final before = evaluatePreflight(await probe.gather(settings));
      expect(before.where((i) => i.blocks), isEmpty, reason: '$before');

      // Session A starts florestad, then "crashes" (never stops it).
      final sessionA = FlorestadProcessManager(
        startProcess: (e, args) => Process.start(e, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrumPort',
          '--connect',
          '127.0.0.1:$deadPeer',
          '--disable-dns-seeds',
        ]),
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
        store: ManagedNodeStore(paths),
      );
      expect(
        (await sessionA.start(
          executablePath: exe,
          settings: settings,
        )).isRight(),
        isTrue,
      );
      final pid = (sessionA.state as ProcessRunning).pid;
      addTearDown(() => Process.killPid(pid, ProcessSignal.sigkill));
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while ((await rpc.getBlockchainInfo()).isLeft()) {
        if (DateTime.now().isAfter(deadline)) fail('RPC never came up');
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect((await ManagedNodeStore(paths).read())?.pid, pid);

      // NODE-05 while it runs: the RPC port is now taken.
      final during = evaluatePreflight(await probe.gather(settings));
      expect(
        during.map((i) => i.title),
        contains('Port ${settings.effectiveRpcPort} is in use'),
      );

      // Session B: a fresh manager with the same app data adopts it.
      final sessionB = FlorestadProcessManager(
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
        store: ManagedNodeStore(paths),
        inspector: SystemProcessInspector(),
      );
      expect(await sessionB.reattach(), isTrue);
      expect(sessionB.state, isA<ProcessAdopted>());
      expect((sessionB.state as ProcessAdopted).pid, pid);

      // Stopping from session B shuts the real node down.
      expect((await sessionB.stop()).isRight(), isTrue);
      expect(sessionB.state, const ProcessStopped(null));
      expect(await SystemProcessInspector().commandLine(pid), isNull);
      expect(await ManagedNodeStore(paths).read(), isNull);
      expect((await rpc.getBlockchainInfo()).isLeft(), isTrue);
      expect(
        File('${temp.path}/data/regtest/debug.log').existsSync(),
        isTrue,
        reason: 'adopted output is only available in debug.log',
      );
      await sessionB.dispose();
    },
    skip: _florestad == null
        ? 'Set FLORESTAD_PATH to a florestad binary to run this test'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
