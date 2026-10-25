import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../core/errors/failure.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../installation/domain/next_action.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/node_process_state.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import '../domain/peer.dart';
import '../domain/preflight.dart';
import '../domain/sync_progress.dart';
import 'node_controller.dart';
import 'status_labels.dart';

/// Figma "Overview" (frame 1:14488): status banner, then Syncing, Backfill,
/// Network Peers and Active Services cards. Every number comes from the
/// node; what florestad does not report is said in words, not drawn.
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
    final readiness = ref.watch(nodeReadinessProvider);
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final next = ref.watch(nextActionProvider);
    final installed =
        next.value is OpenNodeManagement ||
        next.value is ConfigureNode ||
        next.value is UpdateFloresta;

    return DashPage(
      children: [
        if (!installed && next.hasValue && !status.isExternallyManaged) ...[
          Notice(
            tone: Tone.warning,
            title: 'Floresta is not ready to run',
            message:
                'The florestad executable was not found or could not be '
                'used.',
            action: OutlinedButton(
              onPressed: () => context.go('/installation'),
              child: const Text('Open Installation'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (status.process case final ProcessCrashed crashed) ...[
          CrashNotice(crashed),
          const SizedBox(height: 16),
        ],
        if (readiness.stalledFor case final idle?) ...[
          StalledNotice(status: status, readiness: readiness, idle: idle),
          const SizedBox(height: 16),
        ],
        if (status.disk case final disk? when disk.alert != null) ...[
          Notice(
            tone: disk.alert == PreflightSeverity.blocking
                ? Tone.danger
                : Tone.warning,
            title: disk.alert == PreflightSeverity.blocking
                ? 'The disk is almost full'
                : 'Disk space is running low',
            message:
                'Only ${formatBytes(disk.freeBytes!)} free where Floresta keeps '
                'its data. ${disk.alert == PreflightSeverity.blocking ? 'Stop the node and free up space, or it may fail.' : 'Syncing may stop if the disk fills up.'}',
          ),
          const SizedBox(height: 16),
        ],
        for (final w in status.preflightWarnings) ...[
          Notice(
            tone: Tone.warning,
            title: w.title,
            message: [w.message, ?w.recovery].join(' '),
          ),
          const SizedBox(height: 16),
        ],
        if (!network.isMainnet) ...[
          Notice(
            tone: Tone.warning,
            title: '${network.label}: test network',
            message:
                'Coins on this network have no value. Switch to Mainnet in '
                'Settings to follow the real Bitcoin network.',
          ),
          const SizedBox(height: 16),
        ],
        _StatusBanner(status, readiness, installed: installed),
        const SizedBox(height: 24),
        const DashColumns(children: [_SyncCard(), BackfillCard()]),
        const SizedBox(height: 24),
        const DashColumns(children: [_PeersCard(), _ServicesCard()]),
      ],
    );
  }
}

class _StatusBanner extends ConsumerWidget {
  const _StatusBanner(this.status, this.readiness, {required this.installed});
  final NodeStatus status;
  final NodeReadiness readiness;
  final bool installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final short = StatusLabels.short(readiness, status);
    final tone = DashToneColors.of(short.tone);
    final colors = tone == DashTone.neutral
        ? (fg: t.textPrimary, bg: t.surface, border: t.border)
        : tone.colors(context);
    final process = StatusLabels.process(status);
    final controller = ref.read(nodeControllerProvider.notifier);

    Future<void> run(Future<dynamic> Function() action) async {
      final result = await action();
      if (!context.mounted) return;
      result.fold((Failure f) => showFailure(context, f), (_) {});
    }

    final message = switch (short.label) {
      'Syncing' =>
        'Floresta is catching up to the network tip. You can leave it '
            'running in the background.',
      'Stopped' =>
        'Floresta is not running. Start it to sync and serve your '
            'watch-only wallets.',
      _ =>
        StatusLabels.readiness(readiness, status).caption ??
            process.caption ??
            '',
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
                if (tone == DashTone.warning)
                  DashIconBlock.asset(
                    DashIcons.statusSyncing,
                    size: 32,
                    iconSize: 16,
                    color: colors.fg,
                    borderColor: colors.border,
                  )
                else
                  DashIconBlock(
                    switch (tone) {
                      DashTone.success => Icons.check_circle_outline,
                      DashTone.danger => Icons.error_outline,
                      _ => Icons.power_settings_new,
                    },
                    size: 32,
                    iconSize: 18,
                    color: tone == DashTone.neutral ? t.textPrimary : colors.fg,
                    borderColor: colors.border,
                  ),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
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
                      if (message.isNotEmpty)
                        Text(message, style: DashText.body(context)),
                      const SizedBox(height: 4),
                      // Who runs the process: ours, adopted, or external.
                      Wrap(
                        spacing: 4,
                        children: [
                          Text(
                            process.label,
                            style: DashText.small(
                              context,
                              color: t.textPrimary,
                            ),
                          ),
                          if (process.caption case final c?) ...[
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
              if (status.canStart)
                DashButton(
                  'Start node',
                  style: DashButtonStyle.primary,
                  icon: Icons.play_arrow_rounded,
                  onPressed: installed ? () => run(controller.start) : null,
                )
              else
                DashButton(
                  'Go to Sync',
                  style: DashButtonStyle.primary,
                  onPressed: () => context.go('/sync'),
                ),
              DashButton(
                'Logs',
                style: DashButtonStyle.secondary,
                onPressed: () => context.go('/logs'),
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

/// "~ 14,444 blocks" when the tip is an estimate from peers.
String behindText(SyncProgress p) => p.behind == 0
    ? 'Up to date'
    : '${p.tipIsEstimate ? '~ ' : ''}${formatInt(p.behind)} blocks';

/// What the percentage measures, per phase (SYNC-02, SYNC-06).
String fractionMeaning(SyncProgress p, {required bool snapshotApplied}) =>
    switch (p.step) {
      SyncStep.headers =>
        'Block headers downloaded, against the tip reported by peers',
      SyncStep.blocks =>
        snapshotApplied
            ? 'Blocks after the Utreexo snapshot verified by this node'
            : 'Blocks verified by this node',
      SyncStep.live => 'Synced with the network',
    };

class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final p = ref.watch(syncProgressProvider);
    final b = ref.watch(verificationBreakdownProvider);
    final fraction = p?.fraction;
    final live = p?.step == SyncStep.live;
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashCardHeader(
            asset: DashIcons.syncingIbd,
            title: live ? 'Synced' : 'Syncing (IBD)',
            trailing: DashTag(
              p == null ? 'Waiting for the node' : 'Phase: ${p.step.phase}',
              tone: p == null ? DashTone.neutral : DashTone.info,
              large: true,
            ),
          ),
          const SizedBox(height: 24),
          Tooltip(
            message: p == null
                ? 'Needs the node API'
                : fractionMeaning(
                    p,
                    snapshotApplied: b?.snapshotApplied ?? false,
                  ),
            child: Text(
              fraction == null ? '—' : formatPercent1(fraction),
              style: DashText.big(context),
            ),
          ),
          const SizedBox(height: 16),
          if (fraction != null && p != null)
            DashBar(
              fraction: fraction,
              color: live ? t.successDot : t.warning,
              label: fractionMeaning(
                p,
                snapshotApplied: b?.snapshotApplied ?? false,
              ),
            )
          else
            const SizedBox(height: 12),
          const SizedBox(height: 24),
          DashStatRow(
            'Current Height',
            p == null ? '—' : formatInt(p.currentHeight),
          ),
          DashStatRow(
            'Target Height',
            p == null ? '—' : formatInt(p.targetHeight),
          ),
          DashStatRow(
            'Behind',
            p == null ? '—' : behindText(p),
            valueColor: (p?.behind ?? 0) > 0 ? t.warningText : null,
          ),
          const Spacer(),
          const DashDivider(),
          DashButton(
            'View Sync Details',
            height: 48,
            expand: true,
            onPressed: () => context.go('/sync'),
          ),
        ],
      ),
    );
  }
}

/// Backfill state from settings and the node. florestad 0.9.1 re-checks the
/// assumed history in the background but reports no progress for it, so
/// there is no percentage or bar here.
class BackfillCard extends ConsumerWidget {
  const BackfillCard({super.key, this.detailed = false});

  /// The Sync screen's wide variant.
  final bool detailed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final status = ref.watch(nodeControllerProvider);
    final b = ref.watch(verificationBreakdownProvider);
    final snapshot = settings.snapshotHeight;
    final (state, text) = !settings.assumeUtreexo || snapshot == 0
        ? (
            'Not needed',
            'This node validates every block itself from the start, so '
                'there is no assumed history to re-check.',
          )
        : !settings.backfill
        ? (
            'Off',
            'Blocks 0 to ${formatInt(snapshot)} stay accepted from the '
                'Utreexo snapshot. Turn backfill on in Settings to re-check '
                'them.',
          )
        : status.api != ApiReachability.reachable
        ? ('Not running', 'Backfill runs while the node runs.')
        : !(b?.snapshotApplied ?? false)
        ? (
            'Waiting',
            'Starts once the node applies the Utreexo snapshot at block '
                '${formatInt(snapshot)}.',
          )
        : (
            'Running',
            'Validating historical blocks (0 to ${formatInt(snapshot)}) in '
                'the background to improve security over time. Floresta '
                '0.9.1 does not report how far it has got.',
          );
    final tag = !settings.assumeUtreexo || snapshot == 0
        ? const DashTag('Mode: not needed', large: true)
        : settings.backfill
        ? const DashTag(
            'Mode: ON (recommended on desktop)',
            tone: DashTone.info,
            large: true,
          )
        : const DashTag('Mode: OFF', large: true);
    const help =
        'Backfill allows you to use the wallet immediately while full '
        'validation happens later.';

    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashCardHeader(
            asset: DashIcons.backfill,
            title: detailed
                ? 'Background Backfill${state == 'Running' ? ' Active' : ''}'
                : 'Backfill',
            subtitle: detailed
                ? 'Validating historical blocks in the background to improve '
                      'security over time.'
                : null,
            trailing: tag,
          ),
          const SizedBox(height: 24),
          Text(state, style: DashText.big(context)),
          const SizedBox(height: 8),
          Text(text, style: DashText.body(context)),
          if (detailed) const SizedBox(height: 8) else const Spacer(),
          const DashDivider(),
          const DashHelpBox(help),
        ],
      ),
    );
  }
}

class _PeersCard extends ConsumerWidget {
  const _PeersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final peers = ref.watch(nodeControllerProvider.select((s) => s.peers));
    final ready = peers?.where((p) => p.isReady).toList();
    final counts = ready == null ? null : PeerCounts.of(ready);

    Widget box(String label, int? value) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        color: t.subtle,
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 18, color: t.textSecondary)),
            const SizedBox(height: 4),
            Text(
              value == null ? '—' : '$value',
              style: DashText.title(context),
            ),
          ],
        ),
      ),
    );

    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashCardHeader(
            asset: DashIcons.peers,
            title: 'Network Peers',
            trailing: DashTag(
              counts == null ? 'No data' : '${counts.total} Connected',
              tone: counts == null ? DashTone.neutral : DashTone.info,
              large: true,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              box('Inbound', counts?.inbound),
              const SizedBox(width: 16),
              box('Outbound', counts?.outbound),
            ],
          ),
          const SizedBox(height: 16),
          DashStatRow(
            'Transport Protocols',
            counts == null ? '—' : 'v2: ${counts.v2}  •  v1: ${counts.v1}',
          ),
          const Spacer(),
          const DashDivider(),
          DashButton(
            'View Peers',
            height: 48,
            expand: true,
            onPressed: () => context.go('/peers'),
          ),
        ],
      ),
    );
  }
}

class _ServicesCard extends ConsumerWidget {
  const _ServicesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final up = status.api == ApiReachability.reachable;
    final electrum = 'tcp://127.0.0.1:${settings.network.electrumPort}';
    final (eStatus, eTone) = switch (status.electrum) {
      ElectrumCheck.ok => ('Ready $electrum', DashTone.success),
      ElectrumCheck.unreachable => ('Not answering', DashTone.warning),
      ElectrumCheck.wrongNetwork => ('Wrong network', DashTone.danger),
      ElectrumCheck.unknown when up => ('Checking', DashTone.neutral),
      ElectrumCheck.unknown => ('Off', DashTone.disabled),
    };
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DashCardHeader(
            asset: DashIcons.activeServices,
            title: 'Active Services',
          ),
          const SizedBox(height: 24),
          DashServiceRow(name: 'Electrum', status: eStatus, tone: eTone),
          const SizedBox(height: 8),
          DashServiceRow(
            name: 'Wallet-Watch',
            status: up ? 'Ready' : 'Off',
            tone: up ? DashTone.success : DashTone.disabled,
          ),
          const SizedBox(height: 8),
          // Always loopback and unauthenticated; never exposed (ADR-0001).
          DashServiceRow(
            name: 'RPC (local only)',
            status: up ? '127.0.0.1:${settings.effectiveRpcPort}' : 'Off',
            tone: up ? DashTone.neutral : DashTone.disabled,
          ),
          const SizedBox(height: 8),
          // This app never enables florestad's metrics endpoint.
          const DashServiceRow(
            name: 'Metrics (Prometheus)',
            status: 'Off',
            tone: DashTone.disabled,
          ),
          const Spacer(),
          const DashDivider(),
          DashButton(
            'Manage Services',
            height: 48,
            expand: true,
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
    );
  }
}

class CrashNotice extends StatelessWidget {
  const CrashNotice(this.crashed, {super.key});
  final ProcessCrashed crashed;

  @override
  Widget build(BuildContext context) {
    final message = crashed.looksLikePortConflict
        ? 'The RPC or Electrum port is already in use. Another Floresta or '
              'Bitcoin Core instance may be running. Stop it, or change the '
              'RPC port in Settings.'
        : crashed.exitCode == null
        ? 'Floresta stopped on its own while this app was reconnected to it. '
              'Its debug.log in the data folder explains why.'
        : 'Floresta stopped with exit code ${crashed.exitCode}. The last log '
              'lines (Logs) usually explain why.';
    return Notice(
      tone: Tone.danger,
      icon: Icons.error_outline,
      title: 'The node exited unexpectedly',
      message: message,
    );
  }
}

class StalledNotice extends StatelessWidget {
  const StalledNotice({
    super.key,
    required this.status,
    required this.readiness,
    required this.idle,
  });
  final NodeStatus status;
  final NodeReadiness readiness;
  final Duration idle;

  @override
  Widget build(BuildContext context) {
    final utreexo =
        status.peers?.where((p) => p.isReady && p.supportsUtreexo).length ?? 0;
    final ready = status.peers?.where((p) => p.isReady).length ?? 0;
    return Notice(
      tone: Tone.danger,
      title: 'The node is not making progress',
      message:
          'Heights have not changed for ${formatDuration(idle)}. '
          '${readiness.missingUtreexoPeers
              ? 'Floresta needs at least $minUtreexoPeers peers that serve Utreexo proofs to verify new blocks, and has $utreexo right now. Floresta\'s own list of such peers is out of date, so this app also looks for them and adds the ones it can verify (see Sync). Progress depends on how many such peers are online, not on your setup.'
              : ready == 0
              ? 'It has no connected peers: check your internet connection or firewall.'
              : 'It has peers, so they may not be serving the data it needs; the log (Logs) may say why.'}',
    );
  }
}
