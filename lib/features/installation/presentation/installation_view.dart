import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/floresta_version.dart';
import '../domain/installation.dart';
import '../domain/installer.dart';
import '../domain/next_action.dart';
import '../data/artifact_downloader.dart' show isLoopbackUrl;
import 'install_controller.dart';
import 'installation_providers.dart';

/// Detection result, next action and install guidance. Shared by the
/// onboarding step and the Installation page.
class InstallationView extends ConsumerWidget {
  const InstallationView({super.key, this.primaryAction});

  /// Shown when Floresta is usable (e.g. "Continue" during onboarding).
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
    final detection = ref.watch(installationDetectionProvider);
    final next = ref.watch(nextActionProvider);
    final configured = ref.watch(
      settingsControllerProvider.select((s) => s.executablePath),
    );
    final automatic = ref.watch(installerProvider) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PlatformPanel(platform),
        const SizedBox(height: 16),
        Panel(
          title: 'Floresta executable',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (configured != null)
                TextButton(
                  onPressed: () => _setExecutable(context, ref, null),
                  child: const Text('Use automatic detection'),
                ),
              const SizedBox(width: 4),
              OutlinedButton(
                onPressed: () => _chooseExecutable(context, ref, platform),
                child: const Text('Choose file…'),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Check again',
                onPressed: detection.isLoading
                    ? null
                    : () => ref.invalidate(installationDetectionProvider),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          child: switch (detection) {
            AsyncData(:final value) => _DetectionResult(value),
            AsyncError(:final error) => Notice(
              tone: Tone.danger,
              title: 'Detection failed unexpectedly',
              message: '$error',
            ),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Looking for florestad…'),
                ],
              ),
            ),
          },
        ),
        const SizedBox(height: 16),
        if (next.value case final action?)
          _NextActionPanel(
            action,
            primaryAction: primaryAction,
            automaticInstall: automatic,
          ),
        const SizedBox(height: 16),
        if (automatic) ...[const _InstallerPanel(), const SizedBox(height: 16)],
        _BuildFromSourcePanel(platform),
      ],
    );
  }

  Future<void> _chooseExecutable(
    BuildContext context,
    WidgetRef ref,
    HostPlatform platform,
  ) async {
    final file = await openFile(confirmButtonText: 'Use this executable');
    if (file == null || !context.mounted) return;
    await _setExecutable(context, ref, file.path);
  }

  Future<void> _setExecutable(
    BuildContext context,
    WidgetRef ref,
    String? path,
  ) async {
    final controller = ref.read(settingsControllerProvider.notifier);
    final current = ref.read(settingsControllerProvider);
    final result = await controller.update(
      current.copyWith(executablePath: Option.fromNullable(path)),
    );
    if (!context.mounted) return;
    result.fold((f) => showFailure(context, f), (_) {});
  }
}

class _PlatformPanel extends StatelessWidget {
  const _PlatformPanel(this.platform);
  final HostPlatform platform;

  @override
  Widget build(BuildContext context) {
    final (label, tone, detail) = switch (platform.upstreamSupport) {
      UpstreamSupport.ciTested => (
        'Tested upstream',
        Tone.success,
        'Floresta\'s continuous integration builds and tests on this '
            'platform.',
      ),
      UpstreamSupport.untested => (
        'Not tested upstream',
        Tone.warning,
        'Floresta may build from source here, but upstream does not test '
            'this platform.',
      ),
      UpstreamSupport.unsupported => (
        'Unsupported',
        Tone.danger,
        'There is no known way to run Floresta on this platform.',
      ),
    };
    return Panel(
      title: 'This computer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueRow('Operating system', platform.os.label),
          KeyValueRow('Architecture', platform.arch.label),
          const SizedBox(height: 8),
          StatusIndicator(label: label, caption: detail, tone: tone),
        ],
      ),
    );
  }
}

class _DetectionResult extends StatelessWidget {
  const _DetectionResult(this.result);
  final Either<Failure, FlorestaInstallation> result;

  @override
  Widget build(BuildContext context) {
    return result.match(
      (failure) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Notice(
            tone: failure is ExecutableNotFoundFailure
                ? Tone.warning
                : Tone.danger,
            title: failure.title,
            message: [failure.message, ?failure.recovery].join('\n'),
          ),
          if (failure case ExecutableNotFoundFailure(:final searchedPaths))
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Searched locations',
                  style: context.text.bodySmall,
                ),
                children: [
                  for (final p in searchedPaths)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        p,
                        style: monoStyle(context, size: 11.5),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      (install) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusIndicator(
            label: 'Found florestad ${install.version}',
            caption: install.source.label,
            tone: install.version.isSupported ? Tone.success : Tone.warning,
          ),
          const SizedBox(height: 10),
          KeyValueRow('Path', install.executablePath, mono: true),
          KeyValueRow(
            'Build',
            install.version.isReleaseBuild
                ? 'Release ${install.version}'
                : 'Development build (${install.version})',
          ),
        ],
      ),
    );
  }
}

class _NextActionPanel extends StatelessWidget {
  const _NextActionPanel(
    this.action, {
    this.primaryAction,
    this.automaticInstall = false,
  });
  final NextAction action;
  final Widget? primaryAction;
  final bool automaticInstall;

  @override
  Widget build(BuildContext context) {
    final (title, message, tone) = switch (action) {
      InstallFloresta() => (
        'Next: install Floresta',
        automaticInstall
            ? 'Install it automatically below. Building from source is '
                  'still possible if you prefer.'
            : 'Automatic installation is not configured in this build. '
                  'Choose an existing florestad above, or build it from '
                  'source with the steps below, then check again.',
        Tone.info,
      ),
      FixInstallation(:final failure) => (
        'Next: fix the selected executable',
        failure.recovery ?? 'Choose a working florestad executable.',
        Tone.warning,
      ),
      UpdateFloresta(:final installation) => (
        'Update recommended',
        'Floresta ${installation.version} is older than '
            '${FlorestaVersion.minimumSupported}, the oldest version this app '
            'was written for. Some screens may not work.',
        Tone.warning,
      ),
      ConfigureNode() => (
        'Next: set up your node',
        'Floresta is installed. Choose a network and where to store data.',
        Tone.success,
      ),
      OpenNodeManagement() => (
        'Ready',
        'Floresta is installed and configured.',
        Tone.success,
      ),
    };
    final usable =
        action is ConfigureNode ||
        action is OpenNodeManagement ||
        action is UpdateFloresta;
    return Notice(
      tone: tone,
      title: title,
      message: message,
      icon: usable ? Icons.check_circle_outline : Icons.arrow_forward,
      action: usable ? primaryAction : null,
    );
  }
}

class _BuildFromSourcePanel extends StatelessWidget {
  const _BuildFromSourcePanel(this.platform);
  final HostPlatform platform;

  @override
  Widget build(BuildContext context) {
    // Commands from upstream doc/build-macos.md and doc/build-unix.md.
    final prerequisites = switch (platform.os) {
      HostOs.macos => const [
        'xcode-select --install',
        'brew install boost cmake gcc pkgconf',
      ],
      HostOs.linux => const [
        'sudo apt-get install -y build-essential cmake curl clang '
            'libclang-dev git libssl-dev pkg-config libboost-all-dev',
      ],
      _ => const <String>[],
    };
    return Panel(
      title: 'Build from source',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Run these in a terminal. They follow the official Floresta build '
            'guide. Rust 1.85 or newer is required (rustup.rs).',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 12),
          if (prerequisites.isEmpty)
            const Notice(
              tone: Tone.warning,
              title: 'No upstream build guide for this OS',
              message:
                  'Floresta\'s CI builds on Windows, but the project '
                  'does not document the Windows build prerequisites.',
            ),
          for (final c in prerequisites) ...[
            CommandBlock(c),
            const SizedBox(height: 6),
          ],
          const CommandBlock(
            'git clone https://github.com/getfloresta/Floresta.git && '
            'cd Floresta && git checkout v0.9.1',
          ),
          const SizedBox(height: 6),
          const CommandBlock('cargo install --path ./bin/florestad --locked'),
          const SizedBox(height: 10),
          Text(
            'cargo installs into ~/.cargo/bin, which this app searches '
            'automatically.',
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Runs the configured [Installer]. Shown only when this build has a
/// release source.
class _InstallerPanel extends ConsumerWidget {
  const _InstallerPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installer = ref.watch(installerProvider);
    if (installer == null) return const SizedBox.shrink();
    final source = ref.watch(releaseSourceProvider);
    final run = ref.watch(installControllerProvider);
    final controller = ref.read(installControllerProvider.notifier);
    final platform = ref.watch(hostPlatformProvider);
    final badge = source != null && isLoopbackUrl(source.manifestUrl)
        ? 'DEVELOPMENT SOURCE'
        : null;
    final supported = installer.supports(platform);
    final done = run.progress is InstallCompleted;

    return Panel(
      title: 'Automatic installation',
      trailing: badge == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: context.colors.warning),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: context.text.labelSmall?.copyWith(
                  color: context.colors.warning,
                ),
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Downloads Floresta, checks its signature and checksum, confirms '
            'that it runs on this computer, and installs it for your user '
            'only. No administrator password is needed, and your blockchain '
            'data is never touched.',
            style: context.text.bodySmall,
          ),
          if (!supported) ...[
            const SizedBox(height: 12),
            Notice(
              tone: Tone.warning,
              title: 'Not available for ${platform.label}',
              message: 'Choose an existing florestad executable instead.',
            ),
          ],
          const SizedBox(height: 12),
          if (run.progress case final p?) ...[
            _ProgressLine(p),
            const SizedBox(height: 12),
          ],
          if (!done)
            Align(
              alignment: Alignment.centerLeft,
              child: run.running
                  ? OutlinedButton(
                      onPressed: controller.cancel,
                      child: const Text('Cancel'),
                    )
                  : OutlinedButton(
                      onPressed: run.running || !supported
                          ? null
                          : controller.start,
                      child: Text(
                        run.progress is InstallFailed
                            ? 'Try again'
                            : 'Install Floresta',
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine(this.progress);
  final InstallProgress progress;

  @override
  Widget build(BuildContext context) {
    return switch (progress) {
      InstallResolving() => const Text('Checking the published release…'),
      InstallDownloading(:final fraction) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Downloading ${(fraction * 100).round()}%'),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
        ],
      ),
      InstallVerifying() => const Text('Verifying the download…'),
      InstallInstalling() => const Text('Installing…'),
      InstallCompleted(:final executablePath) => StatusIndicator(
        label: 'Floresta installed',
        caption: executablePath,
        tone: Tone.success,
      ),
      InstallFailed(:final reason, :final recovery) => Notice(
        tone: Tone.warning,
        title: 'Nothing was installed',
        message: [reason, ?recovery].join(' '),
      ),
    };
  }
}
