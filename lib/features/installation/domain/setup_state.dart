import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'installation.dart';
import 'installer.dart';

/// Where this computer stands with Floresta, in one place.
///
/// Before this existed, the Installation screen answered "is Floresta
/// installed?" twice: the detection panel from [FlorestaInstallation]
/// detection, the automatic-install panel from the current install run
/// only. After a restart (no run yet), or with a florestad found on PATH,
/// the first said "Ready" while the second still offered "Install Floresta"
/// (2026-10-28). Every installation container now reads this state, derived
/// by [resolve] from all the sources at once.
///
/// "Ready to start" means set up, not synced: sync state lives in the node's
/// readiness, never here.
sealed class SetupState {
  const SetupState();

  /// The single decision function; pure, so every branch is unit-tested.
  ///
  /// - [detection]: null while detection runs.
  /// - [installing]/[lastInstall]: the app's install run, if any.
  /// - [nodeActive]: this app's florestad process is starting or running.
  /// - [nodeAnswering]: a node answers on the configured RPC port.
  static SetupState resolve({
    required Either<Failure, FlorestaInstallation>? detection,
    required bool installing,
    required InstallProgress? lastInstall,
    required bool automaticInstall,
    required bool onboardingComplete,
    required bool useExistingNode,
    required bool nodeActive,
    required bool nodeAnswering,
  }) {
    if (useExistingNode) {
      return onboardingComplete
          ? ExistingNode(answering: nodeAnswering)
          : const ExistingNode(answering: false, configured: false);
    }
    // An install in progress wins: detection is re-run when it completes.
    if (installing) return Installing(lastInstall);
    if (detection == null) return const SetupChecking();
    return detection.match(
      (failure) => switch (failure) {
        ExecutableNotFoundFailure() => switch (lastInstall) {
          final InstallFailed f => InstallFailedState(
            f,
            automaticInstall: automaticInstall,
          ),
          _ => NotInstalled(automaticInstall: automaticInstall),
        },
        _ => Unusable(failure),
      },
      (installation) {
        if (!onboardingComplete) {
          return ConfigurationRequired(installation);
        }
        if (nodeActive || nodeAnswering) return Running(installation);
        return ReadyToStart(installation);
      },
    );
  }

  /// Floresta can be used: a working executable, or a node elsewhere.
  bool get usable => switch (this) {
    ConfigurationRequired() || ReadyToStart() || Running() => true,
    ExistingNode(:final configured) => configured,
    _ => false,
  };

  /// The found executable, when there is one.
  FlorestaInstallation? get installation => switch (this) {
    ConfigurationRequired(:final installation) => installation,
    ReadyToStart(:final installation) => installation,
    Running(:final installation) => installation,
    _ => null,
  };

  /// One short line naming the state, the same on every screen.
  String get label => switch (this) {
    SetupChecking() => 'Looking for Floresta',
    NotInstalled() => 'Floresta is not installed',
    Installing() => 'Installing Floresta',
    InstallFailedState(:final failure) => failure.title,
    Unusable(:final failure) => failure.title,
    ConfigurationRequired() => 'Floresta is installed',
    ReadyToStart() => 'Set up and ready to start',
    Running() => 'Floresta is running',
    ExistingNode(configured: false) => 'Connect to a running node',
    ExistingNode(answering: true) => 'Connected to your node',
    ExistingNode() => 'Your node is not answering',
  };
}

/// Detection has not answered yet.
final class SetupChecking extends SetupState {
  const SetupChecking();
}

/// No florestad on this computer.
final class NotInstalled extends SetupState {
  const NotInstalled({required this.automaticInstall});

  /// This build can install it (it has a release source).
  final bool automaticInstall;
}

final class Installing extends SetupState {
  const Installing(this.progress);
  final InstallProgress? progress;
}

/// The last install attempt failed and nothing usable was found.
final class InstallFailedState extends SetupState {
  const InstallFailedState(this.failure, {required this.automaticInstall});
  final InstallFailed failure;
  final bool automaticInstall;
}

/// A florestad was found but cannot be used (not executable, no version).
final class Unusable extends SetupState {
  const Unusable(this.failure);
  final Failure failure;
}

/// Installed; the node has not been set up yet (network, storage…).
final class ConfigurationRequired extends SetupState {
  const ConfigurationRequired(this.installation);
  @override
  final FlorestaInstallation installation;
}

/// Installed and set up; the node is not running.
final class ReadyToStart extends SetupState {
  const ReadyToStart(this.installation);
  @override
  final FlorestaInstallation installation;
}

/// Installed, set up, and a node is running or answering.
final class Running extends SetupState {
  const Running(this.installation);
  @override
  final FlorestaInstallation installation;
}

/// The app connects to a node that runs elsewhere and runs none itself.
final class ExistingNode extends SetupState {
  const ExistingNode({required this.answering, this.configured = true});
  final bool answering;
  final bool configured;
}
