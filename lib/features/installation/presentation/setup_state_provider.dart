import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';

import '../../node/domain/node_status.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/setup_state.dart';
import 'install_controller.dart';
import 'installation_providers.dart';

/// The one installation/setup state every screen shows ([SetupState]).
final setupStateProvider = Provider<SetupState>((ref) {
  final detection = ref.watch(installationDetectionProvider);
  final run = ref.watch(installControllerProvider);
  final settings = ref.watch(settingsControllerProvider);
  final node = ref.watch(nodeControllerProvider);
  return SetupState.resolve(
    detection: switch (detection) {
      _ when detection.isLoading => null,
      AsyncData(:final value) => value,
      // Detection returns failures as values; a throw is a bug, but it
      // must not leave the screen "Looking for Floresta" forever.
      AsyncError(:final error) => Left(
        InstallationFailure(
          stage: 'detect',
          message: 'Looking for florestad failed unexpectedly ($error).',
          recovery: 'Check again, or choose the florestad file yourself.',
        ),
      ),
      _ => null,
    },
    installing: run.running,
    lastInstall: run.progress,
    automaticInstall: ref.watch(installerProvider) != null,
    onboardingComplete: settings.onboardingComplete,
    useExistingNode: settings.useExistingNode,
    nodeActive: node.process.isActive,
    nodeAnswering: node.api == ApiReachability.reachable,
  );
});
