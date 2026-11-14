import 'dart:io';

import 'package:floresta_desktop/core/errors/failure.dart';
import 'package:floresta_desktop/features/node/data/florestad_launch_args.dart';
import 'package:floresta_desktop/features/node/data/florestad_process_manager.dart';
import 'package:floresta_desktop/features/node/domain/node_process_state.dart';
import 'package:floresta_desktop/features/node/domain/swift_sync.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_process.dart';

void main() {
  group('florestadLaunchArgs', () {
    test('binds RPC to loopback and never daemonizes', () {
      final args = florestadLaunchArgs(
        const NodeSettings(network: BitcoinNetwork.signet, logToFile: false),
      );
      expect(args, [
        '--network',
        'signet',
        '--rpc-address',
        '127.0.0.1:38332',
        // Swift Sync by default, which needs assume-utreexo off.
        '--no-assume-utreexo',
        // No birthday, so filters start at signet's snapshot.
        '--filters-start-height',
        '296870',
      ]);
      expect(args, isNot(contains('--daemon')));
    });

    test('never asks florestad for debug logs, whatever the settings', () {
      // v0.9.1 logs loaded descriptors at debug level
      // (json_rpc/server.rs "Descriptor pushed"); they are private.
      for (final n in BitcoinNetwork.values) {
        for (final s in [
          NodeSettings(network: n),
          NodeSettings(
            network: n,
            dataDir: '/d',
            rpcPort: 9999,
            disableCompactFilters: true,
            assumeUtreexo: false,
            walletBirthdayYear: 2020,
          ),
        ]) {
          final args = florestadLaunchArgs(s);
          expect(args, isNot(contains('--debug')));
          expect(args, isNot(contains('-d')));
          expect(args, isNot(contains('--daemon')));
        }
      }
    });

    test('passes optional flags only when set', () {
      final args = florestadLaunchArgs(
        const NodeSettings(
          network: BitcoinNetwork.regtest,
          dataDir: '/data/floresta',
          rpcPort: 19000,
          disableCompactFilters: true,
        ),
      );
      expect(args, [
        '--network',
        'regtest',
        '--data-dir',
        '/data/floresta',
        '--rpc-address',
        '127.0.0.1:19000',
        '--log-to-file',
        '--no-cfilters',
        // Regtest has no built-in state: validates from the first block.
        '--no-assume-utreexo',
      ]);
    });

    test('fast start: no backfill keeps assume-utreexo', () {
      final args = florestadLaunchArgs(
        const NodeSettings(
          logToFile: false,
          swiftSync: false,
          assumeUtreexo: true,
          backfill: false,
        ),
      );
      expect(args, contains('--no-backfill'));
      expect(args, isNot(contains('--no-assume-utreexo')));
    });

    test('Swift Sync wins over a stored assume-utreexo', () {
      final args = florestadLaunchArgs(
        const NodeSettings(logToFile: false, assumeUtreexo: true),
      );
      expect(args, contains('--no-assume-utreexo'));
      expect(args, isNot(contains('--no-backfill')));
    });

    test('Swift Sync is not offered where no hints exist', () {
      const s = NodeSettings(network: BitcoinNetwork.testnet4);
      expect(s.syncMethod, SyncMethod.full);
      expect(florestadLaunchArgs(s), contains('--no-assume-utreexo'));
    });

    test('fast start: no assume-utreexo makes backfill moot', () {
      final args = florestadLaunchArgs(
        const NodeSettings(
          logToFile: false,
          assumeUtreexo: false,
          backfill: false,
        ),
      );
      expect(args, contains('--no-assume-utreexo'));
      expect(args, isNot(contains('--no-backfill')));
    });
  });

  group('FlorestadProcessManager', () {
    late FakeProcess process;
    late List<(String, List<String>)> launches;
    late bool rpcStopAccepted;

    FlorestadProcessManager manager({bool isWindows = false}) =>
        FlorestadProcessManager(
          startProcess: (exe, args) async {
            launches.add((exe, args));
            return process;
          },
          requestGracefulStop: (_) async => rpcStopAccepted,
          isWindows: isWindows,
          gracefulTimeout: const Duration(milliseconds: 50),
          interruptTimeout: const Duration(milliseconds: 50),
          killTimeout: const Duration(milliseconds: 50),
        );

    setUp(() {
      process = FakeProcess();
      launches = [];
      rpcStopAccepted = true;
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('starts, captures output and reports running', () async {
      final m = manager();
      final r = await m.start(
        executablePath: '/bin/florestad',
        settings: const NodeSettings(),
      );
      expect(r.isRight(), isTrue);
      expect(m.state, isA<ProcessRunning>());
      expect(launches.single.$1, '/bin/florestad');

      process.emitStdout('INFO Electrum Server is running at 127.0.0.1:60001');
      await pump();
      expect(m.logs.last.text, contains('Electrum Server is running'));
    });

    test('counts Swift Sync block lines but keeps few in the log', () async {
      // swift_sync_ctx.rs at 3a47993; about 650 such lines a second on
      // signet would push everything else out of the 2000-line buffer.
      final m = manager();
      await m.start(
        executablePath: '/bin/florestad',
        settings: const NodeSettings(network: BitcoinNetwork.signet),
      );
      process.emitStdout(
        '2026-11-13 18:27:08  INFO wire: Performing SwiftSync up to height '
        '320000 with up to 10 validation workers',
      );
      final total = FlorestadProcessManager.swiftSyncBlockLineEvery + 5;
      for (var h = 1; h <= total; h++) {
        process.emitStdout(
          '2026-11-13 18:27:08  INFO wire: SwiftSync block: block_hash=00ab '
          'height=$h tx_count=1',
        );
      }
      process.emitStdout('INFO wire: an unrelated line');
      await pump();
      expect(m.swiftSync.phase, SwiftSyncPhase.running);
      expect(m.swiftSync.processed, total);
      expect(m.swiftSync.stopHeight, 320000);
      final kept = m.logs.where((l) => l.text.contains('SwiftSync block:'));
      expect(kept, hasLength(1));
      expect(m.logs.last.text, contains('an unrelated line'));
    });

    test('a new start forgets the previous Swift Sync', () async {
      final m = manager();
      await m.start(
        executablePath: '/bin/florestad',
        settings: const NodeSettings(),
      );
      process.emitStdout(
        'Performing SwiftSync up to height 970000 with up to 8 validation '
        'workers',
      );
      await pump();
      expect(m.swiftSync.isRunning, isTrue);
      await process.exit(0);
      await pump();
      process = FakeProcess(pid: 4243);
      await m.start(
        executablePath: '/bin/florestad',
        settings: const NodeSettings(),
      );
      expect(m.swiftSync, const SwiftSyncProgress());
    });

    test('stop goes to the port the node was started on', () async {
      // Regression (2026-10-26): switching signet -> mainnet changed the
      // settings first, so "stop" went to 8332 while signet listened on
      // 38332, and the app had to escalate to SIGINT.
      final ports = <int>[];
      final m = FlorestadProcessManager(
        startProcess: (exe, args) async => process,
        requestGracefulStop: (port) async {
          ports.add(port);
          process.exit(0);
          return true;
        },
        gracefulTimeout: const Duration(milliseconds: 50),
      );
      await m.start(
        executablePath: '/f',
        settings: const NodeSettings(network: BitcoinNetwork.signet),
      );
      final r = await m.stop();
      expect(r.isRight(), isTrue);
      expect(ports, [38332]);
    });

    test('refuses a second start while active', () async {
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      final r = await m.start(
        executablePath: '/f',
        settings: const NodeSettings(),
      );
      expect(r.getLeft().toNullable(), isA<ProcessStateFailure>());
      expect(launches, hasLength(1));
    });

    test('reports launch failures', () async {
      final m = FlorestadProcessManager(
        startProcess: (e, a) async =>
            throw const ProcessException('/f', [], 'No such file', 2),
        requestGracefulStop: (_) async => true,
      );
      final r = await m.start(
        executablePath: '/f',
        settings: const NodeSettings(),
      );
      expect(r.getLeft().toNullable(), isA<ProcessStartFailure>());
      expect(m.state, isA<ProcessFailedToStart>());
    });

    test('an unrequested exit is a crash with the log tail', () async {
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      process.emitStdout(
        'ERROR Failed to bind to address 127.0.0.1:38332. Floresta is '
        'probably already running.',
      );
      await pump();
      await process.exit(255);
      await pump();
      final state = m.state as ProcessCrashed;
      expect(state.exitCode, 255);
      expect(state.looksLikePortConflict, isTrue);
    });

    test('stops gracefully over RPC without signals', () async {
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      final stopping = m.stop();
      await pump();
      expect(m.state, isA<ProcessStopping>());
      await process.exit(0);
      expect((await stopping).isRight(), isTrue);
      expect(m.state, const ProcessStopped(0));
      expect(process.signals, isEmpty);
    });

    test('escalates to SIGINT when RPC stop is not honoured', () async {
      process.onSignal = (s) => s == ProcessSignal.sigint ? 0 : null;
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      expect((await m.stop()).isRight(), isTrue);
      expect(process.signals, [ProcessSignal.sigint]);
      expect(m.state, isA<ProcessStopped>());
    });

    test('escalates to SIGKILL as a last resort', () async {
      rpcStopAccepted = false;
      process.onSignal = (s) => s == ProcessSignal.sigkill ? -9 : null;
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      expect((await m.stop()).isRight(), isTrue);
      expect(process.signals, [ProcessSignal.sigint, ProcessSignal.sigkill]);
    });

    test('skips SIGINT on Windows', () async {
      rpcStopAccepted = false;
      process.onSignal = (s) => -1;
      final m = manager(isWindows: true);
      await m.start(executablePath: '/f', settings: const NodeSettings());
      await m.stop();
      expect(process.signals, [ProcessSignal.sigkill]);
    });

    test('fails stop when idle', () async {
      expect(
        (await manager().stop()).getLeft().toNullable(),
        isA<ProcessStateFailure>(),
      );
    });

    test('redacts extended keys from daemon output', () async {
      final m = manager();
      await m.start(executablePath: '/f', settings: const NodeSettings());
      process.emitStdout('INFO Descriptor pushed: wpkh(${FakeKeys.xpub}/0/*)');
      await pump();
      expect(m.logs.last.text, isNot(contains(FakeKeys.xpub)));
    });
  });
}
