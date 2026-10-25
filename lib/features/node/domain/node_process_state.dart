import 'package:equatable/equatable.dart';

/// Lifecycle of a florestad process started by this app.
///
/// This says nothing about whether the RPC API answers or the chain is
/// synced; those are tracked separately (see `NodeStatus`).
sealed class NodeProcessState extends Equatable {
  const NodeProcessState();

  bool get isActive => false;

  @override
  List<Object?> get props => [];
}

final class ProcessIdle extends NodeProcessState {
  const ProcessIdle();
}

final class ProcessStarting extends NodeProcessState {
  const ProcessStarting();
  @override
  bool get isActive => true;
}

final class ProcessRunning extends NodeProcessState {
  const ProcessRunning(this.pid, this.startedAt);
  final int pid;
  final DateTime startedAt;
  @override
  bool get isActive => true;
  @override
  List<Object?> get props => [pid, startedAt];
}

/// A florestad this app started before it last quit, found still running
/// and taken over (same pid and executable). Its output since the restart is
/// not captured; florestad's own `debug.log` has it when logging to file.
final class ProcessAdopted extends NodeProcessState {
  const ProcessAdopted(this.pid, this.startedAt);
  final int pid;
  final DateTime startedAt;
  @override
  bool get isActive => true;
  @override
  List<Object?> get props => [pid, startedAt];
}

final class ProcessStopping extends NodeProcessState {
  const ProcessStopping(this.pid);
  final int pid;
  @override
  bool get isActive => true;
  @override
  List<Object?> get props => [pid];
}

/// Exited after the user asked it to stop. [exitCode] is null for an adopted
/// process, whose exit status the OS reports only to its original parent.
final class ProcessStopped extends NodeProcessState {
  const ProcessStopped(this.exitCode);
  final int? exitCode;
  @override
  List<Object?> get props => [exitCode];
}

/// Exited without being asked to. [lastOutput] holds the tail of the log so
/// the UI can show why.
final class ProcessCrashed extends NodeProcessState {
  const ProcessCrashed(this.exitCode, this.lastOutput);

  /// Null for an adopted process (see [ProcessStopped.exitCode]).
  final int? exitCode;
  final List<String> lastOutput;

  /// florestad logs "Failed to bind to address … Floresta is probably
  /// already running." and exits when the RPC port is taken; an Electrum
  /// port clash surfaces as `FailedToBindElectrumServer`.
  bool get looksLikePortConflict => lastOutput.any((l) {
    final lower = l.toLowerCase();
    return lower.contains('failed to bind') ||
        lower.contains('failedtobind') ||
        lower.contains('address already in use');
  });

  @override
  List<Object?> get props => [exitCode, lastOutput];
}

final class ProcessFailedToStart extends NodeProcessState {
  const ProcessFailedToStart(this.reason);
  final String reason;
  @override
  List<Object?> get props => [reason];
}
