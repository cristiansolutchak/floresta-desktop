import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../core/processes/process_inspector.dart';
import '../../../core/processes/process_starter.dart';
import '../../settings/domain/node_settings.dart';
import '../domain/managed_node_record.dart';
import '../domain/node_process_manager.dart';
import '../domain/node_process_state.dart';
import '../domain/swift_sync.dart';
import 'florestad_launch_args.dart';
import 'managed_node_store.dart';

/// Requests a graceful shutdown over RPC; returns true if the node accepted.
/// Sends florestad's `stop` RPC to 127.0.0.1:[rpcPort] and says whether it
/// was accepted. The port is the one the node was started with: the
/// settings may already point at another network (network switch).
typedef GracefulStopRequest = Future<bool> Function(int rpcPort);

/// Supervises florestad as a direct child process.
///
/// Stop escalation follows upstream behaviour (`bin/florestad/src/main.rs`):
/// the main loop checks its stop flag every 5 s and then waits up to 10 s
/// for shutdown, and only SIGINT (`ctrl_c`) is handled — SIGTERM would
/// terminate without a clean shutdown. So: `stop` RPC → wait
/// [gracefulTimeout] → SIGINT (Unix only) → wait [interruptTimeout] →
/// SIGKILL.
///
/// With a [ManagedNodeStore], the identity of the running child is persisted
/// so that after an app crash or force-quit the next session can [reattach]
/// to it instead of treating it as a stranger.
class FlorestadProcessManager implements NodeProcessManager {
  FlorestadProcessManager({
    required GracefulStopRequest requestGracefulStop,
    ProcessStarter? startProcess,
    ManagedNodeStore? store,
    ProcessInspector? inspector,
    bool? isWindows,
    this.gracefulTimeout = const Duration(seconds: 30),
    this.interruptTimeout = const Duration(seconds: 15),
    this.killTimeout = const Duration(seconds: 5),
    this.watchInterval = const Duration(seconds: 1),
    int logCapacity = 2000,
  }) : _requestGracefulStop = requestGracefulStop,
       _start = startProcess ?? startSystemProcess,
       _store = store,
       _inspector = inspector ?? SystemProcessInspector(),
       _isWindows = isWindows ?? Platform.isWindows,
       _logs = LogBuffer(capacity: logCapacity);

  final ManagedNodeStore? _store;
  final ProcessInspector _inspector;

  /// How often an adopted process is checked for exit.
  final Duration watchInterval;
  ManagedNodeRecord? _adopted;
  Completer<void>? _adoptedGone;
  Timer? _watch;
  bool _checking = false;

  final GracefulStopRequest _requestGracefulStop;

  /// RPC port of the node this manager started.
  int? _rpcPort;
  final ProcessStarter _start;
  final bool _isWindows;
  final Duration gracefulTimeout;
  final Duration interruptTimeout;
  final Duration killTimeout;
  final LogBuffer _logs;

  final _stateController = StreamController<NodeProcessState>.broadcast();
  final _logController = StreamController<LogLine>.broadcast();

  NodeProcessState _state = const ProcessIdle();
  Process? _process;
  bool _stopRequested = false;
  Completer<int>? _exited;
  final List<StreamSubscription<String>> _outputSubs = [];

  @override
  NodeProcessState get state => _state;
  @override
  Stream<NodeProcessState> get states => _stateController.stream;
  @override
  List<LogLine> get logs => _logs.lines;
  @override
  Stream<LogLine> get logLines => _logController.stream;

  SwiftSyncProgress _swiftSync = const SwiftSyncProgress();
  @override
  SwiftSyncProgress get swiftSync => _swiftSync;

  /// Of florestad's one-line-per-block Swift Sync output (about 650 lines a
  /// second), only every this many reach the log view; the rest would push
  /// everything else out of it within seconds. All are counted.
  static const swiftSyncBlockLineEvery = 10000;

  @override
  Future<Either<Failure, Unit>> start({
    required String executablePath,
    required NodeSettings settings,
  }) async {
    if (_state.isActive) {
      return const Left(ProcessStateFailure('The node is already running.'));
    }
    final args = florestadLaunchArgs(settings);
    _rpcPort = settings.effectiveRpcPort;
    _stopRequested = false;
    _swiftSync = const SwiftSyncProgress();
    _setState(const ProcessStarting());
    _appLog('Starting $executablePath ${args.join(' ')}');

    final Process process;
    try {
      process = await _start(executablePath, args);
    } on ProcessException catch (e) {
      _setState(ProcessFailedToStart(e.message));
      return Left(
        ProcessStartFailure(
          e.message,
          recovery: 'Check the executable in Installation.',
        ),
      );
    }

    _process = process;
    final exited = _exited = Completer<int>();
    _outputSubs.clear();
    _attachOutput(process.stdout, LogSource.stdout);
    _attachOutput(process.stderr, LogSource.stderr);
    unawaited(process.stdin.close().catchError((_) {}));
    unawaited(process.exitCode.then(_onExit));
    // The exit handler may already have run for a process that died
    // immediately; only report running if it has not.
    if (!exited.isCompleted) {
      final now = DateTime.now();
      _setState(ProcessRunning(process.pid, now));
      await _store?.write(
        ManagedNodeRecord(
          pid: process.pid,
          executablePath: executablePath,
          rpcPort: settings.effectiveRpcPort,
          startedAt: now,
        ),
      );
    }
    return const Right(unit);
  }

  @override
  Future<bool> reattach() async {
    final store = _store;
    if (store == null || _state.isActive) return false;
    final record = await store.read();
    if (record == null) return false;
    final command = await _inspector.commandLine(record.pid);
    if (command == null || !record.matches(command)) {
      await store.clear(); // gone, or the pid now belongs to another program
      return false;
    }
    _stopRequested = false;
    _swiftSync = const SwiftSyncProgress();
    _adopted = record;
    _adoptedGone = Completer<void>();
    _appLog(
      'Reconnected to florestad (process ${record.pid}), started '
      '${record.startedAt.toLocal()} by an earlier session of this app. Its '
      'output since then is not shown here; with "Write a log file" on, it '
      'is in debug.log in the data folder.',
    );
    _setState(ProcessAdopted(record.pid, record.startedAt));
    _watch = Timer.periodic(watchInterval, (_) => _checkAdopted());
    return true;
  }

  Future<void> _checkAdopted() async {
    final record = _adopted;
    if (record == null || _checking) return;
    _checking = true;
    try {
      if (!await _isStill(record)) _onAdoptedGone();
    } finally {
      _checking = false;
    }
  }

  Future<bool> _isStill(ManagedNodeRecord record) async {
    final command = await _inspector.commandLine(record.pid);
    return command != null && record.matches(command);
  }

  void _onAdoptedGone() {
    final record = _adopted;
    if (record == null) return;
    _adopted = null;
    _watch?.cancel();
    _watch = null;
    unawaited(_store?.clear());
    _appLog('florestad (process ${record.pid}) exited.');
    _setState(
      _stopRequested
          ? const ProcessStopped(null)
          : const ProcessCrashed(null, [
              'florestad exited while this app was reconnected to it; its '
                  'exit status is not available.',
            ]),
    );
    _adoptedGone?.complete();
  }

  Future<Either<Failure, Unit>> _stopAdopted(ManagedNodeRecord record) async {
    final gone = _adoptedGone!.future;
    if (_state is ProcessStopping) {
      await gone;
      return const Right(unit);
    }
    _stopRequested = true;
    _setState(ProcessStopping(record.pid));
    final accepted = await _requestGracefulStop(
      record.rpcPort,
    ).catchError((_) => false);
    _appLog(
      accepted
          ? 'Sent "stop" over RPC; waiting for shutdown.'
          : 'RPC "stop" was not accepted; escalating.',
    );
    if (accepted && await _waitFor(gone, gracefulTimeout)) {
      return const Right(unit);
    }
    // Signal only after re-checking identity: never signal a reused pid.
    if (!_isWindows && await _isStill(record)) {
      _appLog('Sending SIGINT.');
      _inspector.signal(record.pid, ProcessSignal.sigint);
      if (await _waitFor(gone, interruptTimeout)) return const Right(unit);
    }
    if (await _isStill(record)) {
      _appLog('Forcing termination.');
      _inspector.signal(record.pid, ProcessSignal.sigkill);
    }
    if (await _waitFor(gone, killTimeout)) return const Right(unit);
    return const Left(
      ProcessStateFailure(
        'The node process did not exit. You may need to end it from your '
        "system's activity monitor.",
      ),
    );
  }

  Future<bool> _waitFor(Future<void> done, Duration timeout) async {
    try {
      await done.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<Either<Failure, Unit>> stop() async {
    if (_adopted case final record?) return _stopAdopted(record);
    final process = _process;
    final exited = _exited;
    if (process == null || exited == null || !_state.isActive) {
      return const Left(ProcessStateFailure('The node is not running.'));
    }
    if (_state is ProcessStopping) {
      await exited.future;
      return const Right(unit);
    }
    _stopRequested = true;
    _setState(ProcessStopping(process.pid));

    final accepted = await _requestGracefulStop(
      _rpcPort ?? 0,
    ).catchError((_) => false);
    _appLog(
      accepted
          ? 'Sent "stop" over RPC; waiting for shutdown.'
          : 'RPC "stop" was not accepted; escalating.',
    );
    if (accepted && await _waitExit(exited, gracefulTimeout)) {
      return const Right(unit);
    }

    if (!_isWindows) {
      _appLog('Sending SIGINT.');
      process.kill(ProcessSignal.sigint);
      if (await _waitExit(exited, interruptTimeout)) return const Right(unit);
    }

    _appLog('Forcing termination.');
    process.kill(ProcessSignal.sigkill);
    if (await _waitExit(exited, killTimeout)) return const Right(unit);
    return const Left(
      ProcessStateFailure(
        'The node process did not exit. You may need to end it from your '
        "system's activity monitor.",
      ),
    );
  }

  Future<bool> _waitExit(Completer<int> exited, Duration timeout) async {
    try {
      await exited.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _onExit(int code) {
    _appLog('florestad exited with code $code.');
    _process = null;
    unawaited(_store?.clear());
    final tail = _logs.lines.reversed
        .take(20)
        .map((l) => l.text)
        .toList()
        .reversed
        .toList();
    _setState(
      _stopRequested ? ProcessStopped(code) : ProcessCrashed(code, tail),
    );
    _exited?.complete(code);
  }

  void _attachOutput(Stream<List<int>> stream, LogSource source) {
    _outputSubs.add(
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _onOutput(source, line)),
    );
  }

  void _onOutput(LogSource source, String line) {
    _swiftSync = _swiftSync.next(line);
    if (SwiftSyncProgress.isBlockLine(line) &&
        _swiftSync.processed % swiftSyncBlockLineEvery != 0) {
      return;
    }
    _emit(source, line);
  }

  void _appLog(String text) => _emit(LogSource.app, text);

  void _emit(LogSource source, String text) {
    final line = _logs.add(source, text);
    if (!_logController.isClosed) _logController.add(line);
  }

  void _setState(NodeProcessState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  @override
  Future<void> dispose() async {
    if (_state.isActive) await stop();
    _watch?.cancel();
    for (final s in _outputSubs) {
      await s.cancel();
    }
    await _stateController.close();
    await _logController.close();
  }
}
