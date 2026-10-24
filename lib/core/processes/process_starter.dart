import 'dart:io';

/// Seam over `Process.start` so process-driving code can be tested with a
/// fake [Process] instead of spawning real executables.
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

Future<Process> startSystemProcess(String executable, List<String> arguments) {
  // runInShell stays false: arguments are passed verbatim to the executable,
  // so user-provided paths can never be interpreted by a shell.
  return Process.start(executable, arguments, runInShell: false);
}
