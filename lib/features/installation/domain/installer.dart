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

/// Moving the verified binary into place and recording it.
final class InstallInstalling extends InstallProgress {
  const InstallInstalling();
}

final class InstallCompleted extends InstallProgress {
  const InstallCompleted(this.executablePath);
  final String executablePath;
  @override
  List<Object?> get props => [executablePath];
}

final class InstallFailed extends InstallProgress {
  const InstallFailed(this.reason, {this.recovery});
  final String reason;
  final String? recovery;
  @override
  List<Object?> get props => [reason, recovery];
}

/// Installs florestad into an app-managed location.
///
/// Implementation: `ManagedInstaller` (signed manifest, verified download).
/// Installs start only on an explicit user action and never run downloaded
/// scripts or request elevation. There is no simulated installer: a build
/// without a release source offers no automatic installation at all.
abstract interface class Installer {
  bool supports(HostPlatform platform);

  Stream<InstallProgress> install(HostPlatform platform);

  /// Asks a running install to stop. The stream then ends in
  /// [InstallFailed]; a partial download is kept for resuming.
  void cancel();
}
