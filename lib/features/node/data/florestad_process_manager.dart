import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../core/processes/process_starter.dart';
import '../../settings/domain/node_settings.dart';
import '../domain/node_process_manager.dart';
import '../domain/node_process_state.dart';
import 'florestad_launch_args.dart';

/// Requests a graceful shutdown over RPC; returns true if the node accepted.
typedef GracefulStopRequest = Future<bool> Function();

/// Supervises florestad as a direct child process.
///
/// Stop escalation follows upstream behaviour (`bin/florestad/src/main.rs`):
/// the main loop checks its stop flag every 5 s and then waits up to 10 s
/// for shutdown, and only SIGINT (`ctrl_c`) is handled — SIGTERM would
/// terminate without a clean shutdown. So: `stop` RPC → wait
/// [gracefulTimeout] → SIGINT (Unix only) → wait [interruptTimeout] →
/// SIGKILL.
class FlorestadProcessManager implements NodeProcessManager {
  FlorestadProcessManager({
    required GracefulStopRequest requestGracefulStop,
    ProcessStarter? startProcess,
    bool? isWindows,
    this.gracefulTimeout = const Duration(seconds: 30),
    this.interruptTimeout = const Duration(seconds: 15),
    this.killTimeout = const Duration(seconds: 5),
    int logCapacity = 2000,
  }) : _requestGracefulStop = requestGracefulStop,
       _start = startProcess ?? startSystemProcess,
       _isWindows = isWindows ?? Platform.isWindows,
       _logs = LogBuffer(capacity: logCapacity);

  final GracefulStopRequest _requestGracefulStop;
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

  @override
  Future<Either<Failure, Unit>> start({
    required String executablePath,
    required NodeSettings settings,
  }) async {
    if (_state.isActive) {
      return const Left(ProcessStateFailure('The node is already running.'));
    }
    final args = florestadLaunchArgs(settings);
    _stopRequested = false;
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
      _setState(ProcessRunning(process.pid, DateTime.now()));
    }
    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> stop() async {
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

    final accepted = await _requestGracefulStop().catchError((_) => false);
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
          .listen((line) => _emit(source, line)),
    );
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
    for (final s in _outputSubs) {
      await s.cancel();
    }
    await _stateController.close();
    await _logController.close();
  }
}
