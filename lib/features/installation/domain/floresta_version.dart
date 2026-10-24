import 'package:equatable/equatable.dart';

/// A florestad version as printed by `florestad --version`.
///
/// Upstream builds the string from `git describe --tags --always --dirty`
/// when it starts with `v`, otherwise from `v<Cargo version>`
/// (`bin/florestad/build.rs`). Clap prefixes the binary name, so real output
/// looks like `florestad v0.9.1` or `florestad v0.9.1-14-g3a47993-dirty`.
class FlorestaVersion extends Equatable implements Comparable<FlorestaVersion> {
  const FlorestaVersion(
    this.major,
    this.minor,
    this.patch, {
    this.commitsSinceTag = 0,
    this.commit,
    this.dirty = false,
    this.raw,
  });

  final int major;
  final int minor;
  final int patch;

  /// Non-zero when built from a commit after the tag.
  final int commitsSinceTag;
  final String? commit;
  final bool dirty;
  final String? raw;

  /// Oldest version whose RPC surface this app was written against
  /// (`v0.9.x`, the latest release on 2026-10-24).
  static const minimumSupported = FlorestaVersion(0, 9, 0);

  static final _pattern = RegExp(
    r'v?(\d+)\.(\d+)\.(\d+)(?:-(\d+)-g([0-9a-f]{4,40}))?(-dirty)?',
  );

  /// Parses the first version-looking token in [output]; null if none.
  static FlorestaVersion? tryParse(String output) {
    final m = _pattern.firstMatch(output);
    if (m == null) return null;
    return FlorestaVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      commitsSinceTag: m[4] == null ? 0 : int.parse(m[4]!),
      commit: m[5],
      dirty: m[6] != null,
      raw: output.trim(),
    );
  }

  bool get isReleaseBuild => commitsSinceTag == 0 && !dirty;
  bool get isSupported => compareTo(minimumSupported) >= 0;

  @override
  int compareTo(FlorestaVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (commitsSinceTag, other.commitsSinceTag),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator <(FlorestaVersion other) => compareTo(other) < 0;
  bool operator >(FlorestaVersion other) => compareTo(other) > 0;

  @override
  String toString() {
    final base = 'v$major.$minor.$patch';
    final suffix = commitsSinceTag > 0 ? '-$commitsSinceTag-g$commit' : '';
    return '$base$suffix${dirty ? '-dirty' : ''}';
  }

  @override
  List<Object?> get props => [major, minor, patch, commitsSinceTag, dirty];
}
