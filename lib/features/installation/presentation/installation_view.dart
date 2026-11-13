import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/status_motion.dart';
import '../../node/presentation/status_labels.dart' show formatBytes;
import '../../settings/presentation/settings_controller.dart';
import '../data/artifact_downloader.dart' show isLoopbackUrl;
import '../domain/floresta_version.dart';
import '../domain/installation.dart';
import '../domain/installer.dart';
import '../domain/setup_state.dart';
import 'advanced_setup.dart';
import 'install_controller.dart';
import 'installation_providers.dart';
import 'setup_state_provider.dart';

/// Is Floresta on this computer, and what is the next step? One card driven
/// by [setupStateProvider] (so no two parts of the screen can disagree),
/// then the advanced and alternative ways in second place. Shared by the
/// onboarding step and the Installation page.
class InstallationView extends ConsumerWidget {
  const InstallationView({super.key, this.primaryAction});

  /// Shown when Floresta is usable during onboarding ("Continue").
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(setupStateProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetupCard(state, primaryAction: primaryAction),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => showAdvancedSetup(context),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Advanced setup'),
            ),
            TextButton.icon(
              onPressed: () => showOtherWays(context),
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Other ways to connect'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Points the app at [path] (null: back to automatic detection).
Future<void> setExecutable(
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

Future<void> chooseExecutable(BuildContext context, WidgetRef ref) async {
  final file = await openFile(confirmButtonText: 'Use this florestad');
  if (file == null || !context.mounted) return;
  await setExecutable(context, ref, file.path);
}

class _SetupCard extends ConsumerWidget {
  const _SetupCard(this.state, {this.primaryAction});
  final SetupState state;
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(
      settingsControllerProvider.select((s) => s.executablePath),
    );
    final platform = ref.watch(hostPlatformProvider);
    final installer = ref.watch(installerProvider);
    final supported = installer?.supports(platform) ?? false;
    final install = ref.read(installControllerProvider.notifier);
    final source = ref.watch(releaseSourceProvider);
    final devSource = source != null && isLoopbackUrl(source.manifestUrl);
    final rpcPort = ref.watch(
      settingsControllerProvider.select((s) => s.effectiveRpcPort),
    );

    Widget goOverview() => FilledButton(
      onPressed: () => context.go('/node'),
      child: const Text('Go to Overview'),
    );

    final (Tone tone, IconData icon, String message) = switch (state) {
      SetupChecking() => (
        Tone.neutral,
        Icons.search,
        'Checking this computer for florestad…',
      ),
      NotInstalled(automaticInstall: true) => (
        Tone.info,
        Icons.download_outlined,
        'The app downloads the official Floresta release, checks its '
            'signature and installs it for your user only. No administrator '
            'password is needed, and existing data is never touched.',
      ),
      NotInstalled() => (
        Tone.warning,
        Icons.download_outlined,
        'This build cannot install Floresta by itself. Use a florestad you '
            'already have, or see the other ways to get one.',
      ),
      Installing() => (
        Tone.info,
        Icons.download_outlined,
        'Downloading and verifying the official release.',
      ),
      InstallFailedState(:final failure) => (
        failure.cancelled ? Tone.info : Tone.warning,
        failure.cancelled ? Icons.pause_circle_outline : Icons.error_outline,
        [failure.reason, ?failure.recovery].join(' '),
      ),
      Unusable(:final failure) => (
        Tone.danger,
        Icons.error_outline,
        [failure.message, ?failure.recovery].join(' '),
      ),
      ConfigurationRequired(:final installation) => (
        Tone.success,
        Icons.check_circle_outline,
        'Floresta ${installation.versionLabel} is ready to use. Next, choose a '
            'network and where to keep its data.',
      ),
      ReadyToStart(:final installation) => (
        Tone.success,
        Icons.check_circle_outline,
        'Floresta ${installation.versionLabel} is installed and your node is set '
            'up. Start it from Overview.',
      ),
      Running(:final installation) => (
        Tone.success,
        Icons.check_circle_outline,
        'Version ${installation.versionLabel}. Sync progress and controls are on '
            'Overview.',
      ),
      ExistingNode(:final answering) => (
        answering ? Tone.success : Tone.warning,
        Icons.lan_outlined,
        answering
            ? 'This app uses the node answering at 127.0.0.1:$rpcPort and '
                  'runs none of its own.'
            : 'Nothing answers at 127.0.0.1:$rpcPort. Start the node where '
                  'it runs (Docker, Nix, a terminal); the app connects on '
                  'its own.',
      ),
    };

    final List<Widget> actions = switch (state) {
      SetupChecking() => const [],
      NotInstalled(automaticInstall: true) => [
        FilledButton(
          onPressed: supported ? install.start : null,
          child: const Text('Install Floresta'),
        ),
      ],
      NotInstalled() => [
        FilledButton(
          onPressed: () => chooseExecutable(context, ref),
          child: const Text('Choose florestad…'),
        ),
      ],
      Installing() => [
        OutlinedButton(onPressed: install.cancel, child: const Text('Cancel')),
      ],
      InstallFailedState(:final failure, :final automaticInstall) => [
        if (automaticInstall)
          FilledButton(
            onPressed: supported ? install.start : null,
            child: Text(failure.cancelled ? 'Resume download' : 'Try again'),
          ),
      ],
      Unusable() => [
        FilledButton(
          onPressed: () => chooseExecutable(context, ref),
          child: const Text('Choose another file…'),
        ),
        if (configured != null)
          OutlinedButton(
            onPressed: () => setExecutable(context, ref, null),
            child: const Text('Use automatic detection'),
          ),
      ],
      ConfigurationRequired() => [
        primaryAction ??
            FilledButton(
              onPressed: () => context.go('/onboarding/setup'),
              child: const Text('Set up your node'),
            ),
      ],
      ReadyToStart() || Running() => [primaryAction ?? goOverview()],
      ExistingNode() => [primaryAction ?? goOverview()],
    };

    final color = tone.color(context);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(
                    ShellTitleScope.active(context) ? 0 : 6,
                  ),
                ),
                // A spinner only while work really runs (detection, an
                // install); each state change cross-fades in place.
                child: StatusSwap(
                  stateKey: state.runtimeType,
                  child: state is SetupChecking || state is Installing
                      ? Padding(
                          padding: const EdgeInsets.all(11),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: color,
                            // Reduced motion: a still arc says "in progress".
                            value: MediaQuery.disableAnimationsOf(context)
                                ? 0.3
                                : null,
                          ),
                        )
                      : Center(child: Icon(icon, size: 22, color: color)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: StatusSwap(
                            stateKey: state.label,
                            child: Semantics(
                              header: true,
                              child: Text(
                                state.label,
                                style: context.text.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (devSource &&
                            (state is NotInstalled ||
                                state is Installing ||
                                state is InstallFailedState)) ...[
                          const SizedBox(width: 8),
                          const _Badge('DEVELOPMENT SOURCE'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(message, style: context.text.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
          if (state case NotInstalled(automaticInstall: true) when !supported)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Notice(
                tone: Tone.warning,
                title: 'Not available for ${platform.label}',
                message:
                    'There is no Floresta build for this computer yet. See the '
                    'other ways to connect.',
              ),
            ),
          if (state case ConfigurationRequired(
            :final installation,
          ) when !installation.version.isSupported)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Notice(
                tone: Tone.warning,
                title: 'Update recommended',
                message:
                    'Floresta ${installation.versionLabel} is older than '
                    '${FlorestaVersion.minimumSupported}, the oldest version '
                    'this app was written for. Some screens may not work.',
              ),
            ),
          if (state case Installing(:final progress?)) ...[
            const SizedBox(height: 20),
            _StageSteps(progress),
            const SizedBox(height: 12),
            _ProgressLine(progress),
          ],
          if (state case InstallFailedState(:final failure)) ...[
            const SizedBox(height: 20),
            _StageSteps(failure),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
          if (state.installation case final found?) ...[
            const SizedBox(height: 12),
            _Details(found, configured: configured != null),
          ],
        ],
      ),
    );
  }
}

/// Where the executable is and what it is: support detail, folded away.
class _Details extends ConsumerWidget {
  const _Details(this.installation, {required this.configured});
  final FlorestaInstallation installation;
  final bool configured;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: Text('Details', style: context.text.bodyMedium),
        children: [
          KeyValueRow('Found', installation.source.label),
          KeyValueRow('Path', installation.executablePath, mono: true),
          KeyValueRow(
            'Version',
            installation.isReleaseBuild
                ? 'Release ${installation.versionLabel}'
                : 'Development build (${installation.versionLabel})',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => ref.invalidate(installationDetectionProvider),
                child: const Text('Check again'),
              ),
              OutlinedButton(
                onPressed: () => chooseExecutable(context, ref),
                child: const Text('Use another florestad…'),
              ),
              if (configured)
                TextButton(
                  onPressed: () => setExecutable(context, ref, null),
                  child: const Text('Use automatic detection'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: context.colors.warning),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: context.text.labelSmall?.copyWith(color: context.colors.warning),
      ),
    );
  }
}

/// Upstream's own build steps (doc/build-macos.md, doc/build-unix.md).
class BuildFromSource extends ConsumerWidget {
  const BuildFromSource({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
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
    return Column(
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
                'Floresta\'s CI builds on Windows, but the project does not '
                'document the Windows build prerequisites.',
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
    );
  }
}

/// Release → Download → Verify → Install, with the current one marked.
class _StageSteps extends StatelessWidget {
  const _StageSteps(this.progress);
  final InstallProgress progress;

  @override
  Widget build(BuildContext context) {
    final current = InstallStage.of(progress);
    final failed = progress is InstallFailed;
    final complete = progress is InstallCompleted;
    final colors = context.colors;
    return Row(
      children: [
        for (final s in InstallStage.values)
          Expanded(
            child: Builder(
              builder: (context) {
                final idx = s.index;
                final cur = current?.index ?? InstallStage.values.length;
                final (icon, color, state) = complete || idx < cur
                    ? (Icons.check_circle, colors.success, 'done')
                    : idx == cur && failed
                    ? (Icons.error_outline, colors.warning, 'stopped')
                    : idx == cur
                    ? (
                        Icons.radio_button_checked,
                        Theme.of(context).colorScheme.primary,
                        'current',
                      )
                    : (Icons.radio_button_unchecked, colors.muted, '');
                return Semantics(
                  label: '${s.label}${state.isEmpty ? '' : ', $state'}',
                  excludeSemantics: true,
                  child: Row(
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          s.label,
                          style: context.text.bodySmall?.copyWith(
                            fontWeight: idx == cur ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine(this.progress);
  final InstallProgress progress;

  @override
  Widget build(BuildContext context) {
    return switch (progress) {
      InstallResolving() => const Text(
        'Checking the published release and its signature…',
      ),
      InstallDownloading(:final fraction, :final received, :final total) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Downloading ${(fraction * 100).round()}%'
              '${received != null && total != null ? ' · ${formatBytes(received)} of ${formatBytes(total)}' : ''}',
            ),
            const SizedBox(height: 6),
            AnimatedFraction(
              value: fraction,
              builder: (context, v) => LinearProgressIndicator(value: v),
            ),
          ],
        ),
      InstallVerifying() => const Text(
        'Verifying the checksum and that it runs on this computer…',
      ),
      InstallInstalling() => const Text('Installing…'),
      InstallCompleted() => const Text('Floresta installed'),
      InstallFailed() => const SizedBox.shrink(),
    };
  }
}

/// Failure details as one line, for snackbars and notices.
String failureLine(Failure f) => [f.message, ?f.recovery].join(' ');
