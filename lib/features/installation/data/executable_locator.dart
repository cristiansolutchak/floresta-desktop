import 'dart:io';

import '../../../core/platform/host_platform.dart';
import '../domain/installation.dart';

class ExecutableCandidate {
  const ExecutableCandidate(this.path, this.source);
  final String path;
  final ExecutableSource source;
}

/// Checks whether a path is an existing, executable regular file.
typedef ExecutableCheck = Future<bool> Function(String path);

/// Builds the ordered list of places florestad may live and finds the first
/// usable one.
///
/// Apps launched from Finder/Explorer inherit a minimal PATH that usually
/// lacks `~/.cargo/bin`, which is where `cargo install` (upstream's documented
/// method) puts florestad, so well-known locations are searched explicitly.
class ExecutableLocator {
  ExecutableLocator({
    required this.platform,
    required this.environment,
    ExecutableCheck? isExecutable,
  }) : _isExecutable = isExecutable ?? isExecutableFile;

  final HostPlatform platform;
  final Map<String, String> environment;
  final ExecutableCheck _isExecutable;

  String? get homeDir => platform.os == HostOs.windows
      ? environment['USERPROFILE']
      : environment['HOME'];

  List<ExecutableCandidate> candidates() {
    final name = platform.florestadFileName;
    final sep = platform.pathSeparator;
    final seen = <String>{};
    final result = <ExecutableCandidate>[];

    void add(String dir, ExecutableSource source) {
      if (dir.isEmpty) return;
      final trimmed = dir.endsWith(sep)
          ? dir.substring(0, dir.length - 1)
          : dir;
      final path = '$trimmed$sep$name';
      if (seen.add(path)) result.add(ExecutableCandidate(path, source));
    }

    final pathVar = environment['PATH'] ?? environment['Path'] ?? '';
    for (final dir in pathVar.split(platform.pathListSeparator)) {
      add(dir, ExecutableSource.path);
    }

    final home = homeDir;
    if (home != null) {
      add('$home$sep.cargo${sep}bin', ExecutableSource.wellKnown);
    }
    if (platform.os == HostOs.macos) {
      add('/opt/homebrew/bin', ExecutableSource.wellKnown);
      add('/usr/local/bin', ExecutableSource.wellKnown);
    } else if (platform.os == HostOs.linux) {
      add('/usr/local/bin', ExecutableSource.wellKnown);
      add('/usr/bin', ExecutableSource.wellKnown);
      if (home != null) {
        add('$home$sep.nix-profile${sep}bin', ExecutableSource.wellKnown);
      }
    }
    return result;
  }

  /// Returns the first candidate that is an executable file.
  Future<ExecutableCandidate?> find() async {
    for (final c in candidates()) {
      if (await _isExecutable(c.path)) return c;
    }
    return null;
  }

  Future<bool> isUsable(String path) => _isExecutable(path);
}

Future<bool> isExecutableFile(String path) async {
  final stat = await FileStat.stat(path);
  if (stat.type != FileSystemEntityType.file) return false;
  if (Platform.isWindows) return path.toLowerCase().endsWith('.exe');
  // Any of the owner/group/other execute bits.
  return stat.mode & 0x49 != 0;
}
