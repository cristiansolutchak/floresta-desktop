import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';
import 'app_update.dart';

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
  const InstallDownloading(this.fraction, {this.received, this.total});
  final double fraction;

  /// Bytes so far and expected, when known.
  final int? received;
  final int? total;
  @override
  List<Object?> get props => [fraction, received, total];
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
  const InstallFailed(
    this.reason, {
    this.recovery,
    this.stage,
    this.cancelled = false,
  });
  final String reason;
  final String? recovery;

  /// Where it stopped: one of [InstallStage] names, when known.
  final InstallStage? stage;

  /// Stopped by the user; a partial download is kept for resuming.
  final bool cancelled;

  /// A short headline for the failure, by stage.
  String get title => cancelled
      ? 'Download paused'
      : switch (stage) {
          InstallStage.resolve => 'Could not get the release information',
          InstallStage.download => 'The download did not finish',
          InstallStage.verify => 'The download did not pass verification',
          InstallStage.install => 'Floresta could not be installed',
          null => 'Nothing was installed',
        };

  @override
  List<Object?> get props => [reason, recovery, stage, cancelled];
}

/// The four visible steps of an install, in order.
enum InstallStage {
  resolve('Release'),
  download('Download'),
  verify('Verify'),
  install('Install');

  const InstallStage(this.label);
  final String label;

  static InstallStage? fromName(String name) =>
      values.where((s) => s.name == name).firstOrNull;

  /// The step a progress event belongs to; null once completed.
  static InstallStage? of(InstallProgress p) => switch (p) {
    InstallResolving() => resolve,
    InstallDownloading() => download,
    InstallVerifying() => verify,
    InstallInstalling() => install,
    InstallFailed(:final stage) => stage,
    InstallCompleted() => null,
  };
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

  /// A florestad build newer than the one this app installed, without
  /// installing it (nothing is recorded, not even the manifest's serial).
  /// Null when it is current, or when florestad is not app-managed.
  Future<Either<Failure, FlorestadUpdateOffer?>> checkForUpdate(
    HostPlatform platform,
  );
}
