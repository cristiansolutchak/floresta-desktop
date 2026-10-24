import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/executable_locator.dart';
import '../data/installation_repository_impl.dart';
import '../data/mock_installer.dart';
import '../data/version_probe.dart';
import '../domain/installation.dart';
import '../domain/installation_repository.dart';
import '../domain/installer.dart';
import '../domain/next_action.dart';

final executableLocatorProvider = Provider<ExecutableLocator>(
  (ref) => ExecutableLocator(
    platform: ref.watch(hostPlatformProvider),
    environment: ref.watch(environmentProvider),
  ),
);

final installationRepositoryProvider = Provider<InstallationRepository>(
  (ref) => InstallationRepositoryImpl(
    locator: ref.watch(executableLocatorProvider),
    probe: VersionProbe(),
  ),
);

/// Re-runs whenever the configured executable changes; call
/// `ref.invalidate(installationDetectionProvider)` to re-check on demand.
final installationDetectionProvider =
    FutureProvider<Either<Failure, FlorestaInstallation>>((ref) {
      final configured = ref.watch(
        settingsControllerProvider.select((s) => s.executablePath),
      );
      return ref
          .watch(installationRepositoryProvider)
          .detect(configuredPath: configured);
    });

final nextActionProvider = Provider<AsyncValue<NextAction>>((ref) {
  final onboarded = ref.watch(
    settingsControllerProvider.select((s) => s.onboardingComplete),
  );
  return ref
      .watch(installationDetectionProvider)
      .whenData((d) => NextAction.resolve(d, onboardingComplete: onboarded));
});

/// Only a mock exists; see `MockInstaller` and ADR-0005.
final installerProvider = Provider<Installer>((ref) => const MockInstaller());
