import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../../../core/platform/app_paths.dart';
import '../data/artifact_downloader.dart';
import '../data/executable_locator.dart';
import '../data/existing_node_probe.dart';
import '../data/installation_repository_impl.dart';
import '../data/managed_install_store.dart';
import '../data/managed_installer.dart';
import '../data/release_source.dart';
import '../data/release_trust_store.dart';
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

final appPathsProvider = Provider<AppPaths>(
  (ref) => AppPaths.forPlatform(
    ref.watch(hostPlatformProvider),
    ref.watch(environmentProvider),
  ),
);

final managedInstallStoreProvider = Provider<ManagedInstallStore>(
  (ref) => ManagedInstallStore(ref.watch(appPathsProvider)),
);

final installationRepositoryProvider = Provider<InstallationRepository>(
  (ref) => InstallationRepositoryImpl(
    locator: ref.watch(executableLocatorProvider),
    probe: VersionProbe(),
    managed: ref.watch(managedInstallStoreProvider),
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

/// Lists Floresta-looking Docker containers (Advanced setup).
final dockerProbeProvider = Provider<DockerProbe>(
  (ref) => DockerProbe(
    platform: ref.watch(hostPlatformProvider),
    environment: ref.watch(environmentProvider),
  ),
);

/// Checks a node that runs elsewhere before the app is set to use it.
final existingNodeProbeProvider = Provider<ExistingNodeProbe>(
  (ref) => ExistingNodeProbe(httpClient: ref.watch(httpClientProvider)),
);

/// The release source compiled into this build, or null when none is
/// configured (the default until hosting and signing are decided; see
/// docs/distribution-pipeline-design.md).
final releaseSourceProvider = Provider<ReleaseSource?>(
  (ref) => ReleaseSource.fromEnvironment(),
);

/// The installer for the configured release source, or null when this build
/// has none (then the app offers no automatic installation).
final installerProvider = Provider<Installer?>((ref) {
  final source = ref.watch(releaseSourceProvider);
  if (source == null) return null;
  final paths = ref.watch(appPathsProvider);
  return ManagedInstaller(
    paths: paths,
    source: source,
    downloader: ArtifactDownloader(),
    probe: VersionProbe(),
    store: ref.watch(managedInstallStoreProvider),
    trust: ReleaseTrustStore(paths),
  );
});
