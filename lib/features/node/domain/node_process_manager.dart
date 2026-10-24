import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/logging/log_buffer.dart';
import '../../settings/domain/node_settings.dart';
import 'node_process_state.dart';

/// Supervises one florestad child process.
abstract interface class NodeProcessManager {
  NodeProcessState get state;
  Stream<NodeProcessState> get states;

  List<LogLine> get logs;
  Stream<LogLine> get logLines;

  /// Spawns florestad. Fails if a process is already active.
  Future<Either<Failure, Unit>> start({
    required String executablePath,
    required NodeSettings settings,
  });

  /// Graceful stop with escalation; completes once the process has exited.
  Future<Either<Failure, Unit>> stop();

  Future<void> dispose();
}
