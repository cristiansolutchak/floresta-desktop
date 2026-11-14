/// Opt-in check of Swift Sync with a REAL florestad built from master
/// (`3a47993` or later) on SIGNET, through the app's own code:
///
///   FLORESTAD_SWIFT_SYNC_PATH=/path/to/florestad \
///     flutter test test/integration/swift_sync_signet_test.dart
///
/// Needs the internet: it downloads the signet hints (about 25 MB) from
/// utxohints.store with `SwiftSyncHints`, starts the node with
/// `FlorestadProcessManager` and the app's launch arguments in a fresh temp
/// data dir, waits until the node's output shows Swift Sync processing
/// blocks, checks the RPC meanwhile, then stops the node over RPC. Signet
/// coins have no value; nothing touches mainnet or the app's own data.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_desktop/core/rpc/json_rpc_client.dart';
import 'package:floresta_desktop/features/installation/data/capability_scan.dart';
import 'package:floresta_desktop/features/node/data/florestad_process_manager.dart';
import 'package:floresta_desktop/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_desktop/features/node/data/swift_sync_hints.dart';
import 'package:floresta_desktop/features/node/domain/swift_sync.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _florestad = Platform.environment['FLORESTAD_SWIFT_SYNC_PATH'];

/// Blocks Swift Sync must process before the test is satisfied. Headers
/// took about 3 minutes in the 2026-11-13 spike, then ~650 blocks/s.
const _wantProcessed = 20000;
const _timeout = Duration(minutes: 12);

Future<int> _freeLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test(
    'downloads signet hints and runs Swift Sync with a master florestad',
    () async {
      final exe = _florestad!;
      expect(
        await scanForSwiftSync(exe),
        isTrue,
        reason: 'this florestad has no Swift Sync',
      );

      final dataDir = await Directory.systemTemp.createTemp('floresta_swift_');
      addTearDown(() async {
        if (dataDir.path.contains('floresta_swift_') && dataDir.existsSync()) {
          await dataDir.delete(recursive: true);
        }
      });
      final settings = NodeSettings(
        network: BitcoinNetwork.signet,
        dataDir: dataDir.path,
        rpcPort: await _freeLoopbackPort(),
        logToFile: false,
      );
      expect(settings.syncMethod, SyncMethod.swiftSync);

      // 1. Hints, as a start does.
      final watch = Stopwatch()..start();
      var received = 0;
      final hints = await SwiftSyncHints(
        homeDir: null,
      ).prepare(settings, onProgress: (n) => received = n);
      final ready = hints.match(
        (f) => fail('hints: ${f.message}'),
        (o) => o as HintsReady,
      );
      expect(ready.downloaded, isTrue);
      expect(ready.stopHeight, greaterThan(0));
      printOnFailure('hints: $received bytes in ${watch.elapsed}');
      // ignore: avoid_print
      print(
        'hints: ${(received / 1e6).toStringAsFixed(1)} MB, stop height '
        '${ready.stopHeight}, ${watch.elapsed.inSeconds}s',
      );

      // 2. The node, with the app's own launch arguments.
      final electrumPort = await _freeLoopbackPort();
      final httpClient = http.Client();
      addTearDown(httpClient.close);
      final rpc = NodeRpcRepositoryImpl(
        JsonRpcClient(
          endpoint: settings.rpcEndpoint,
          httpClient: httpClient,
          defaultTimeout: const Duration(seconds: 10),
        ),
      );
      final manager = FlorestadProcessManager(
        // Only the Electrum port is moved, so it cannot clash with a node
        // already running on this machine.
        startProcess: (exe, args) => Process.start(exe, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrumPort',
        ]),
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
      );
      addTearDown(manager.dispose);
      addTearDown(
        () => printOnFailure(
          manager.logs.map((l) => '[${l.source.name}] ${l.text}').join('\n'),
        ),
      );
      expect(
        (await manager.start(
          executablePath: exe,
          settings: settings,
        )).isRight(),
        isTrue,
      );

      // 3. Swift Sync from the node's output; the RPC says 0 validated.
      watch.reset();
      final deadline = DateTime.now().add(_timeout);
      int? validatedDuring;
      while (manager.swiftSync.processed < _wantProcessed) {
        if (!manager.state.isActive) fail('florestad exited: ${manager.state}');
        if (DateTime.now().isAfter(deadline)) {
          fail('Swift Sync not under way in time: ${manager.swiftSync}');
        }
        if (manager.swiftSync.phase
            case SwiftSyncPhase.skipped || SwiftSyncPhase.aborted) {
          fail('Swift Sync did not run: ${manager.swiftSync.reason}');
        }
        if (manager.swiftSync.isRunning) {
          validatedDuring ??= (await rpc.getBlockchainInfo())
              .toNullable()
              ?.validatedHeight;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final swift = manager.swiftSync;
      // ignore: avoid_print
      print(
        'swift sync: ${swift.processed} blocks of ${swift.stopHeight} '
        '(${swift.workers} workers) ${watch.elapsed.inSeconds}s after start; '
        'RPC validated height during it: $validatedDuring',
      );
      expect(swift.phase, SwiftSyncPhase.running);
      expect(swift.stopHeight, ready.stopHeight);
      expect(validatedDuring, 0);
      // The per-block lines were counted, not kept.
      expect(
        manager.logs.where((l) => l.text.contains('SwiftSync block:')).length,
        lessThanOrEqualTo(
          swift.processed ~/ FlorestadProcessManager.swiftSyncBlockLineEvery +
              1,
        ),
      );

      // 4. Clean stop over RPC.
      expect((await manager.stop()).isRight(), isTrue);
    },
    skip: _florestad == null
        ? 'set FLORESTAD_SWIFT_SYNC_PATH to a florestad built from master'
        : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
