import 'package:equatable/equatable.dart';

import 'floresta_version.dart';

/// Where a florestad executable was found.
enum ExecutableSource {
  configured('Selected in settings'),
  path('Found on PATH'),
  wellKnown('Found in a standard install location');

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
