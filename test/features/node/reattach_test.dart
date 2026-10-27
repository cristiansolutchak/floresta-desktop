import 'dart:io';

import 'package:floresta_gui/core/platform/app_paths.dart';
import 'package:floresta_gui/core/processes/process_inspector.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/data/managed_node_store.dart';
import 'package:floresta_gui/features/node/domain/managed_node_record.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_process.dart';

/// Answers `commandLine` from a table the test edits; records signals.
class _FakeInspector implements ProcessInspector {
  final commands = <int, String>{};
  final signals = <(int, ProcessSignal)>[];

  /// Called on each signal; may remove the pid to simulate an exit.
  void Function(int pid, ProcessSignal s)? onSignal;

  @override
  Future<String?> commandLine(int pid) async => commands[pid];

  @override
  bool signal(int pid, ProcessSignal s) {
    signals.add((pid, s));
    onSignal?.call(pid, s);
    return commands.containsKey(pid);
  }
}

const _exe = '/apps/floresta/versions/0.9.1/florestad';
const _cmd = '$_exe --network signet --rpc-address 127.0.0.1:38332';

void main() {
  late Directory root;
  late ManagedNodeStore store;
  late _FakeInspector inspector;
  late bool rpcStopAccepted;

  setUp(() {
    root = Directory.systemTemp.createTempSync('reattach_');
    store = ManagedNodeStore(AppPaths(root));
    inspector = _FakeInspector();
    rpcStopAccepted = true;
  });
  tearDown(() => root.deleteSync(recursive: true));

  FlorestadProcessManager manager({FakeProcess? process}) =>
      FlorestadProcessManager(
        startProcess: (_, _) async => process ?? FakeProcess(),
        requestGracefulStop: (_) async => rpcStopAccepted,
        store: store,
        inspector: inspector,
        isWindows: false,
        gracefulTimeout: const Duration(milliseconds: 200),
        interruptTimeout: const Duration(milliseconds: 200),
        killTimeout: const Duration(milliseconds: 200),
        watchInterval: const Duration(milliseconds: 10),
      );

  Future<void> remember(int pid) => store.write(
    ManagedNodeRecord(
      pid: pid,
      executablePath: _exe,
      rpcPort: 38332,
      startedAt: DateTime.utc(2026, 10, 24),
    ),
  );

  group('ManagedNodeRecord.matches', () {
    final r = ManagedNodeRecord(
      pid: 1,
      executablePath: _exe,
      rpcPort: 38332,
      startedAt: _epoch,
    );
    test('same executable and RPC address', () {
      expect(r.matches(_cmd), isTrue);
    });
    test('a reused pid running something else does not match', () {
      expect(r.matches('/usr/bin/vim notes.txt'), isFalse);
      expect(r.matches('$_exe-other --rpc-address 127.0.0.1:38332'), isFalse);
      expect(
        r.matches('$_exe --rpc-address 127.0.0.1:18442'),
        isFalse,
        reason: 'a different node of ours on another port',
      );
    });
  });

  test('start records the child and a clean exit forgets it', () async {
    final p = FakeProcess(pid: 77);
    final m = manager(process: p);
    await m.start(
      executablePath: _exe,
      settings: const NodeSettings(network: BitcoinNetwork.signet),
    );
    final rec = (await store.read())!;
    expect((rec.pid, rec.executablePath, rec.rpcPort), (77, _exe, 38332));
    await p.exit(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await store.read(), isNull);
  });

  test('adopts its own node after a restart', () async {
    await remember(500);
    inspector.commands[500] = _cmd;
    final m = manager();
    expect(await m.reattach(), isTrue);
    expect(m.state, ProcessAdopted(500, DateTime.utc(2026, 10, 24)));
    expect(m.logs.last.text, contains('Reconnected to florestad'));
    await m.dispose();
  });

  test('a gone or reused pid is not adopted and is forgotten', () async {
    await remember(501);
    expect(await manager().reattach(), isFalse);
    expect(await store.read(), isNull);

    await remember(502);
    inspector.commands[502] = '/usr/bin/vim notes.txt';
    expect(await manager().reattach(), isFalse);
    expect(await store.read(), isNull);
  });

  test('stops an adopted node over RPC and sees it exit', () async {
    await remember(600);
    inspector.commands[600] = _cmd;
    final m = manager();
    await m.reattach();
    final stopping = m.stop();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    inspector.commands.remove(600); // the node exits after "stop"
    expect((await stopping).isRight(), isTrue);
    expect(m.state, const ProcessStopped(null));
    expect(inspector.signals, isEmpty);
    expect(await store.read(), isNull);
  });

  test('escalates to SIGINT when RPC stop is refused', () async {
    await remember(601);
    inspector.commands[601] = _cmd;
    rpcStopAccepted = false;
    inspector.onSignal = (pid, s) {
      if (s == ProcessSignal.sigint) inspector.commands.remove(pid);
    };
    final m = manager();
    await m.reattach();
    expect((await m.stop()).isRight(), isTrue);
    expect(inspector.signals, [(601, ProcessSignal.sigint)]);
    expect(m.state, const ProcessStopped(null));
  });

  test('never signals a pid that now belongs to another program', () async {
    await remember(602);
    inspector.commands[602] = _cmd;
    rpcStopAccepted = false;
    final m = manager();
    await m.reattach();
    // Before escalation, the pid is reused by something else.
    inspector.commands[602] = '/usr/bin/vim notes.txt';
    await m.stop();
    expect(inspector.signals, isEmpty);
  });

  test('an adopted node that exits on its own is reported', () async {
    await remember(603);
    inspector.commands[603] = _cmd;
    final m = manager();
    await m.reattach();
    final next = m.states.first;
    inspector.commands.remove(603);
    final s = await next.timeout(const Duration(seconds: 2));
    expect(s, isA<ProcessCrashed>());
    expect((s as ProcessCrashed).exitCode, isNull);
  });
}

final _epoch = DateTime.utc(2026, 10, 24);
