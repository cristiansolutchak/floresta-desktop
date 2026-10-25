import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../settings/domain/node_settings.dart';
import '../domain/preflight.dart';

/// Runs an executable and returns stdout, or null on failure or timeout.
/// Absolute paths only; never through a shell.
typedef CommandRunner =
    Future<String?> Function(String executable, List<String> arguments);

Future<String?> runSystemCommand(String executable, List<String> args) async {
  try {
    final r = await Process.run(
      executable,
      args,
      runInShell: false,
    ).timeout(const Duration(seconds: 5));
    return r.exitCode == 0 ? r.stdout as String : null;
  } on Object {
    return null;
  }
}

/// Gathers [PreflightFacts] from the real machine: binds the ports, writes a
/// probe file, asks the OS for free space. Never modifies user data: the only
/// file it creates is its own probe, removed immediately.
class PreflightProbe {
  PreflightProbe({required this.homeDir, CommandRunner? run, bool? isWindows})
    : _run = run ?? runSystemCommand,
      _isWindows = isWindows ?? Platform.isWindows;

  final String? homeDir;
  final CommandRunner _run;
  final bool _isWindows;

  Future<PreflightFacts> gather(NodeSettings settings) async {
    final sep = Platform.pathSeparator;
    final dataDir = settings.effectiveDataDir(homeDir: homeDir, separator: sep);
    // florestad creates the directory; check the closest one that exists.
    final existing = _closestExisting(Directory(dataDir));
    final (rpcFree, electrumFree, writable, free) = await (
      portIsFree(settings.effectiveRpcPort),
      portIsFree(settings.network.electrumPort),
      existing == null ? Future.value(null) : canWrite(existing),
      existing == null ? Future.value(null) : freeBytes(existing.path),
    ).wait;
    return PreflightFacts(
      rpcPort: settings.effectiveRpcPort,
      rpcPortFree: rpcFree,
      electrumPort: settings.network.electrumPort,
      electrumPortFree: electrumFree,
      dataDir: dataDir,
      dataDirWritable: writable,
      freeBytes: free,
      looksLikeBitcoinCore: looksLikeBitcoinCore(Directory(dataDir)),
    );
  }

  /// True when nothing listens on 127.0.0.1:[port] (the bind succeeds).
  static Future<bool> portIsFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  static Directory? _closestExisting(Directory dir) {
    var d = dir.absolute;
    while (!d.existsSync()) {
      final parent = d.parent;
      if (parent.path == d.path) return null;
      d = parent;
    }
    return d;
  }

  /// Creates and deletes a uniquely named probe file in [dir].
  static Future<bool> canWrite(Directory dir) async {
    final name = '.floresta-gui-write-test-${Random.secure().nextInt(1 << 32)}';
    final probe = File('${dir.path}${Platform.pathSeparator}$name');
    try {
      await probe.writeAsString('ok', flush: true);
      return true;
    } on FileSystemException {
      return false;
    } finally {
      if (probe.existsSync()) await probe.delete();
    }
  }

  /// Free bytes on the volume holding [path], from the OS. Null if unknown.
  Future<int?> freeBytes(String path) async {
    if (_isWindows) {
      // Untested on Windows (no Windows host yet). Only a validated drive
      // letter reaches the command string, never the user's path.
      final drive = RegExp(r'^([A-Za-z]):').firstMatch(path)?.group(1);
      if (drive == null) return null;
      final out = await _run(
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-PSDrive -Name $drive).Free',
        ],
      );
      return int.tryParse(out?.trim() ?? '');
    }
    // POSIX `df -Pk`: line 2, column 4 is available 1K blocks.
    final out = await _run('/bin/df', ['-Pk', path]);
    final lines = out?.trim().split('\n') ?? const [];
    if (lines.length < 2) return null;
    final cols = lines[1].trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[3]);
    return kb == null ? null : kb * 1024;
  }

  static bool looksLikeBitcoinCore(Directory dir) {
    String p(String name) => '${dir.path}${Platform.pathSeparator}$name';
    return File(p('bitcoin.conf')).existsSync() ||
        (Directory(p('blocks')).existsSync() &&
            Directory(p('chainstate')).existsSync());
  }
}
