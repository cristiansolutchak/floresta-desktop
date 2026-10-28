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
  });

  final String executablePath;
  final ExecutableSource source;
  final FlorestaVersion version;

  @override
  List<Object?> get props => [executablePath, source, version];
}

/// A florestad installed and owned by this app (`current.json`).
class ManagedInstall extends Equatable {
  const ManagedInstall({
    required this.version,
    required this.path,
    required this.sha256,
    this.previous,
  });

  final String version;
  final String path;
  final String sha256;

  /// The install replaced by this one, kept for rollback.
  final ManagedInstall? previous;

  Map<String, Object?> toJson() => {
    'version': version,
    'path': path,
    'sha256': sha256,
    if (previous != null)
      'previous': {
        'version': previous!.version,
        'path': previous!.path,
        'sha256': previous!.sha256,
      },
  };

  static ManagedInstall fromJson(Map<String, Object?> j) {
    final prev = j['previous'] as Map<String, Object?>?;
    return ManagedInstall(
      version: j['version']! as String,
      path: j['path']! as String,
      sha256: j['sha256']! as String,
      previous: prev == null ? null : fromJson(prev),
    );
  }

  @override
  List<Object?> get props => [version, path, sha256, previous];
}
