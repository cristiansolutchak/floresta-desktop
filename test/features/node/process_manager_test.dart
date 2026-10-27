import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/node/data/florestad_launch_args.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
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
        // CFG-08: no birthday, so filters start at signet's snapshot.
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
      ]);
    });

    test('fast start: no backfill keeps assume-utreexo', () {
      final args = florestadLaunchArgs(
        const NodeSettings(logToFile: false, backfill: false),
      );
      expect(args, contains('--no-backfill'));
      expect(args, isNot(contains('--no-assume-utreexo')));
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
