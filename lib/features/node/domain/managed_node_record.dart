import 'package:equatable/equatable.dart';

/// Identity of a florestad started by this app, persisted while it runs.
class ManagedNodeRecord extends Equatable {
  const ManagedNodeRecord({
    required this.pid,
    required this.executablePath,
    required this.rpcPort,
    required this.startedAt,
  });

  final int pid;

  /// Absolute path the process was started with (its argv[0]).
  final String executablePath;
  final int rpcPort;
  final DateTime startedAt;

  /// Whether [commandLine] (from the OS) is this exact florestad: same
  /// executable as argv[0] and the RPC address this app passed. A reused pid
  /// belonging to another program does not match.
  bool matches(String commandLine) {
    final startsRight =
        commandLine == executablePath ||
        commandLine.startsWith('$executablePath ');
    return startsRight && commandLine.contains('127.0.0.1:$rpcPort');
  }

  Map<String, Object?> toJson() => {
    'pid': pid,
    'executablePath': executablePath,
    'rpcPort': rpcPort,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  static ManagedNodeRecord fromJson(Map<String, Object?> m) =>
      ManagedNodeRecord(
        pid: m['pid']! as int,
        executablePath: m['executablePath']! as String,
        rpcPort: m['rpcPort']! as int,
        startedAt: DateTime.parse(m['startedAt']! as String),
      );

  @override
  List<Object?> get props => [pid, executablePath, rpcPort, startedAt];
}
