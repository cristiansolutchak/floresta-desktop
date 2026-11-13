import 'package:equatable/equatable.dart';

import 'floresta_version.dart';

/// Where a florestad executable was found.
enum ExecutableSource {
  configured('Selected in settings'),
  managed('Installed by this app'),
  path('Found on PATH'),
  wellKnown('Found in a standard install location'),
  nix('Found in a Nix profile');

  const ExecutableSource(this.label);
  final String label;
}

/// A florestad executable that exists, ran, and reported a version.
class FlorestaInstallation extends Equatable {
  const FlorestaInstallation({
    required this.executablePath,
    required this.source,
    required this.version,
    this.swiftSync = false,
    this.upstreamRef,
  });

  final String executablePath;
  final ExecutableSource source;
  final FlorestaVersion version;

  /// Built with Swift Sync (florestad master; not v0.9.1). Found by
  /// scanning the executable, since `--version` does not tell.
  final bool swiftSync;

  /// Where an app-managed install came from (`v0.9.1`, `master@<sha>`),
  /// from the signed manifest; null for any other florestad.
  final String? upstreamRef;

  /// The version as people should read it. A pinned master build prints the
  /// last version on master (`florestad v0.9.0`) although it is newer than
  /// v0.9.1, so its commit is shown too: "v0.9.0 (master 3a47993)".
  String get versionLabel => florestaVersionLabel(version, upstreamRef);

  /// A build from a release tag, as opposed to a commit after one.
  bool get isReleaseBuild =>
      version.isReleaseBuild && !(upstreamRef?.startsWith('master@') ?? false);

  @override
  List<Object?> get props => [
    executablePath,
    source,
    version,
    swiftSync,
    upstreamRef,
  ];
}

/// A florestad installed and owned by this app (`current.json`).
class ManagedInstall extends Equatable {
  const ManagedInstall({
    required this.version,
    required this.path,
    required this.sha256,
    this.previous,
    this.upstreamRef,
  });

  final String version;
  final String path;
  final String sha256;

  /// From the manifest it was installed from (see
  /// [FlorestaInstallation.upstreamRef]); null for older records.
  final String? upstreamRef;

  /// The install replaced by this one, kept for rollback.
  final ManagedInstall? previous;

  Map<String, Object?> toJson() => {
    'version': version,
    'path': path,
    'sha256': sha256,
    'upstreamRef': ?upstreamRef,
    if (previous != null)
      'previous': {
        'version': previous!.version,
        'path': previous!.path,
        'sha256': previous!.sha256,
        'upstreamRef': ?previous!.upstreamRef,
      },
  };

  static ManagedInstall fromJson(Map<String, Object?> j) {
    final prev = j['previous'] as Map<String, Object?>?;
    return ManagedInstall(
      version: j['version']! as String,
      path: j['path']! as String,
      sha256: j['sha256']! as String,
      upstreamRef: j['upstreamRef'] as String?,
      previous: prev == null ? null : fromJson(prev),
    );
  }

  @override
  List<Object?> get props => [version, path, sha256, previous, upstreamRef];
}

/// "v0.9.0 (master 3a47993)" for a pinned master build, else "v0.9.1".
String florestaVersionLabel(FlorestaVersion version, String? upstreamRef) {
  final v = '$version';
  final ref = upstreamRef;
  if (ref != null && ref.startsWith('master@') && ref.length >= 14) {
    return '$v (master ${ref.substring(7, 14)})';
  }
  return v;
}
