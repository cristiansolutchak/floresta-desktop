import 'package:equatable/equatable.dart';

import '../../../core/platform/host_platform.dart';

/// States an install attempt moves through. Every real implementation must
/// pass through [InstallVerifying] before [InstallCompleted]; an artifact
/// that cannot be verified must end in [InstallFailed], never be installed.
sealed class InstallProgress extends Equatable {
  const InstallProgress();
  @override
  List<Object?> get props => [];
}

final class InstallResolving extends InstallProgress {
  const InstallResolving();
}

final class InstallDownloading extends InstallProgress {
  const InstallDownloading(this.fraction);
  final double fraction;
  @override
  List<Object?> get props => [fraction];
}

final class InstallVerifying extends InstallProgress {
  const InstallVerifying();
}

final class InstallCompleted extends InstallProgress {
  const InstallCompleted(this.executablePath);
  final String executablePath;
  @override
  List<Object?> get props => [executablePath];
}

final class InstallFailed extends InstallProgress {
  const InstallFailed(this.reason);
  final String reason;
  @override
  List<Object?> get props => [reason];
}

/// Installs florestad into an app-managed location.
///
/// No real implementation exists yet: upstream publishes no binary
/// artifacts or signatures (docs/decisions/0005-…). Implementations must be
/// started by an explicit user action and must never run downloaded scripts
/// or request elevated privileges.
abstract interface class Installer {
  /// True only for the demonstration implementation. The UI must label
  /// anything produced by a mock installer as such.
  bool get isMock;

  bool supports(HostPlatform platform);

  Stream<InstallProgress> install(HostPlatform platform);
}
