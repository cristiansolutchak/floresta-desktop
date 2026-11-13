import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../core/errors/failure.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../../shared/widgets/status_motion.dart';
import '../../installation/presentation/setup_state_provider.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import 'node_controller.dart';
import 'status_labels.dart';

/// Where the dashboard banner is shown; the actions differ.
enum BannerPlace { overview, sync }

/// What the banner says for a state: one sentence, true for that state only.
/// Pure, so the wording per state is unit-tested.
String bannerMessage({
  required StatusLabel short,
  required NodeReadiness readiness,
  required NodeStatus status,
  required bool useExistingNode,
  required int rpcPort,
}) {
  final caption =
      StatusLabels.readiness(readiness, status).caption ??
      StatusLabels.process(status).caption;
  return switch (short.label) {
    // Background running only makes sense while it is actually syncing.
    'Syncing' =>
      'Floresta is catching up to the network tip. You can leave it running '
          'in the background.',
    'Synced' =>
      caption ?? 'Your node follows the network tip; wallets can connect.',
    'Stalled' =>
      'Sync has stopped making progress. The notice above says why and what '
          'the app is doing about it.',
    'Stopped' when useExistingNode =>
      'Nothing answers at 127.0.0.1:$rpcPort. Start your node where it runs '
          '(Docker, Nix, a terminal); the app connects on its own.',
    'Stopped' =>
      'Floresta is not running. Start it to sync and serve your watch-only '
          'wallets.',
    'Preparing' =>
      'Downloading the Swift Sync hints file '
          '(${formatBytes(status.hintsDownload ?? 0)} so far). Floresta '
          'starts as soon as it is in place.',
    'Starting' => 'Floresta is starting. This takes a few seconds.',
    'Stopping' => 'Floresta is shutting down cleanly.',
    'Error' =>
      'Floresta stopped unexpectedly${caption == null ? '' : ' ($caption)'}. '
          'Check the logs, then start it again.',
    _ => caption ?? '',
  };
}

/// "Status: SYNCING" banner with the actions that fit the state. Shared by
/// Overview and Sync, so they can never say different things.
class NodeStatusBanner extends ConsumerWidget {
  const NodeStatusBanner({super.key, this.place = BannerPlace.overview});

  final BannerPlace place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final status = ref.watch(nodeControllerProvider);
    final readiness = ref.watch(nodeReadinessProvider);
    final setup = ref.watch(setupStateProvider);
    final settings = ref.watch(settingsControllerProvider);
    final short = StatusLabels.short(readiness, status);
    final tone = DashToneColors.of(short.tone);
    final colors = tone == DashTone.neutral
        ? (fg: t.textPrimary, bg: t.surface, border: t.border)
        : tone.colors(context);
    final process = StatusLabels.process(status);
    final controller = ref.read(nodeControllerProvider.notifier);
    final existing = settings.useExistingNode;

    Future<void> run(Future<dynamic> Function() action) async {
      final result = await action();
      if (!context.mounted) return;
      result.fold((Failure f) => showFailure(context, f), (_) {});
    }

    final message = bannerMessage(
      short: short,
      readiness: readiness,
      status: status,
      useExistingNode: existing,
      rpcPort: settings.effectiveRpcPort,
    );

    final primary = switch (place) {
      _ when status.canStart && existing => DashButton(
        'Check again',
        style: DashButtonStyle.primary,
        icon: Icons.refresh,
        onPressed: controller.refresh,
      ),
      _ when status.canStart => DashButton(
        'Start node',
        style: DashButtonStyle.primary,
        icon: Icons.play_arrow_rounded,
        onPressed: setup.usable ? () => run(controller.start) : null,
      ),
      BannerPlace.overview => DashButton(
        'Go to Sync',
        style: DashButtonStyle.primary,
        onPressed: () => context.go('/sync'),
      ),
      BannerPlace.sync => DashButton(
        'View Peers',
        style: DashButtonStyle.primary,
        onPressed: () => context.go('/peers'),
      ),
    };

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.border),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 16,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DashIconBlock.child(
                  StatusSwap(
                    stateKey: short.label,
                    child: statusGlyph(
                      context,
                      tone: tone,
                      active: StatusLabels.isActive(short),
                      size: tone == DashTone.warning ? 16 : 18,
                      color: tone == DashTone.neutral
                          ? t.textPrimary
                          : colors.fg,
                      spinningAsset: DashIcons.statusSyncing,
                    ),
                  ),
                  size: 32,
                  borderColor: colors.border,
                ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusSwap(
                        stateKey: short.label,
                        child: Semantics(
                          header: true,
                          child: Text(
                            'Status: ${short.label.toUpperCase()}',
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.4,
                              fontWeight: FontWeight.w500,
                              color: colors.fg,
                            ),
                          ),
                        ),
                      ),
                      if (message.isNotEmpty)
                        AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : statusSwapDuration,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.topLeft,
                            children: [...previous, ?current],
                          ),
                          child: Text(
                            message,
                            key: ValueKey(message),
                            style: DashText.body(context),
                          ),
                        ),
                      const SizedBox(height: 4),
                      // Who runs the process: ours, adopted, or external.
                      Wrap(
                        spacing: 4,
                        children: [
                          Text(
                            existing && !status.process.isActive
                                ? 'Node outside this app'
                                : process.label,
                            style: DashText.small(
                              context,
                              color: t.textPrimary,
                            ),
                          ),
                          // An error's detail is already in the message.
                          if (process.caption case final c?
                              when short.label != 'Error') ...[
                            Text('·', style: DashText.small(context)),
                            Text(c, style: DashText.small(context)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              primary,
              DashButton(
                'Logs',
                style: DashButtonStyle.secondary,
                onPressed: () => context.go('/logs'),
              ),
              if (place == BannerPlace.sync && !status.canStart)
                DashButton(
                  'Refresh',
                  asset: DashIcons.sync,
                  onPressed: controller.refresh,
                ),
              if (status.canStop && !status.isExternallyManaged)
                DashButton(
                  'Restart',
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Restart the node?',
                      message:
                          'Floresta will shut down cleanly and start again. '
                          'Connected wallets will briefly disconnect.',
                      confirmLabel: 'Restart',
                    );
                    if (ok) await run(controller.restart);
                  },
                ),
              if (status.canStop)
                DashButton(
                  'Stop',
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Stop the node?',
                      message: status.isExternallyManaged
                          ? 'This node was started outside this app. It will '
                                'be asked to shut down over RPC and this app '
                                'will not be able to start it the same way.'
                          : 'Floresta will shut down cleanly. Sync progress '
                                'is kept and resumes on the next start.',
                      confirmLabel: 'Stop',
                    );
                    if (ok) await run(controller.stop);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
