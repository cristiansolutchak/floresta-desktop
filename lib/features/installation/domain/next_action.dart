import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'installation.dart';

/// The single most useful next step, derived from detection results.
sealed class NextAction {
  const NextAction();

  /// Pure decision function; kept free of I/O so every branch is unit-tested.
  static NextAction resolve(
    Either<Failure, FlorestaInstallation> detection, {
    required bool onboardingComplete,
  }) {
    return detection.match(
      (failure) => switch (failure) {
        ExecutableNotFoundFailure() => const InstallFloresta(),
        _ => FixInstallation(failure),
      },
      (installation) {
        if (!installation.version.isSupported) {
          return UpdateFloresta(installation);
        }
        return onboardingComplete
            ? OpenNodeManagement(installation)
            : ConfigureNode(installation);
      },
    );
  }
}

final class InstallFloresta extends NextAction {
  const InstallFloresta();
}

final class FixInstallation extends NextAction {
  const FixInstallation(this.failure);
  final Failure failure;
}

final class UpdateFloresta extends NextAction {
  const UpdateFloresta(this.installation);
  final FlorestaInstallation installation;
}

final class ConfigureNode extends NextAction {
  const ConfigureNode(this.installation);
  final FlorestaInstallation installation;
}

final class OpenNodeManagement extends NextAction {
  const OpenNodeManagement(this.installation);
  final FlorestaInstallation installation;
}
