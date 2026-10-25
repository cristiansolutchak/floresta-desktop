import 'dart:io';

/// Reads and signals OS processes this app did not spawn in this session,
/// such as a florestad started before the app was restarted.
abstract interface class ProcessInspector {
  /// The full command line of [pid], or null when no such process exists.
  Future<String?> commandLine(int pid);

  /// Sends [signal]; false when the process is gone or not ours.
  bool signal(int pid, ProcessSignal signal);
}

class SystemProcessInspector implements ProcessInspector {
  SystemProcessInspector({bool? isWindows})
    : _isWindows = isWindows ?? Platform.isWindows;

  final bool _isWindows;

  @override
  Future<String?> commandLine(int pid) async {
    final ProcessResult r;
    try {
      r = _isWindows
          // Untested on Windows (no Windows host yet).
          ? await Process.run(
              r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
              [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                // pid is an int, so nothing user-controlled reaches the
                // command string.
                '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid")'
                    '.CommandLine',
              ],
              runInShell: false,
            ).timeout(const Duration(seconds: 5))
          : await Process.run('/bin/ps', [
              '-p',
              '$pid',
              '-o',
              'command=',
            ], runInShell: false).timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  }

  @override
  bool signal(int pid, ProcessSignal signal) => Process.killPid(pid, signal);
}
