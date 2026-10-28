import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../installation/domain/setup_state.dart';
import '../../installation/presentation/setup_state_provider.dart';
import '../../settings/presentation/settings_controller.dart';
import '../domain/node_process_state.dart';
import '../domain/node_readiness.dart';
import '../domain/node_status.dart';
import '../domain/peer.dart';
import '../domain/preflight.dart';
import '../domain/sync_progress.dart';
import 'node_controller.dart';
import 'node_status_banner.dart';
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
    final setup = ref.watch(setupStateProvider);

    return DashPage(
      children: [
        if (!setup.usable &&
            setup is! SetupChecking &&
            setup is! Installing &&
            !status.isExternallyManaged) ...[
          Notice(
            tone: Tone.warning,
            title: 'Floresta is not ready to run',
            message: '${setup.label}. Installation shows what to do next.',
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
        const NodeStatusBanner(),
        const SizedBox(height: 24),
        const DashColumns(children: [_SyncCard(), BackfillCard()]),
        const SizedBox(height: 24),
        const DashColumns(children: [_PeersCard(), _ServicesCard()]),
      ],
    );
  }
}

/// "~ 14,444 blocks" when the tip is an estimate from peers.
String behindText(SyncProgress p) => !p.tipKnown
    ? 'Unknown'
    : p.behind == 0
    ? 'Up to date'
    : '${p.tipIsEstimate ? '~ ' : ''}${formatInt(p.behind)} blocks';

/// The network tip, or why it is not known yet.
String targetText(SyncProgress p) =>
    p.tipKnown ? formatInt(p.targetHeight) : 'Waiting for peers';

/// What the percentage measures, per phase (SYNC-02, SYNC-06).
String fractionMeaning(SyncProgress p, {required bool snapshotApplied}) =>
    switch (p.step) {
      SyncStep.headers when !p.tipKnown =>
        'Waiting for peers to report the network tip',
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
            p?.leadingStat.label ?? 'Current Height',
            p == null ? '—' : formatInt(p.leadingStat.value),
          ),
          DashStatRow('Target Height', p == null ? '—' : targetText(p)),
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
            asset: DashIcons.syncingIbd,
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
    if (crashed.looksLikeDamagedWalletStore) {
      return const DamagedWalletStoreNotice();
    }
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

/// florestad could not open its watch-only store. Offers to move the store's
/// files aside (never delete them) and start again.
class DamagedWalletStoreNotice extends ConsumerStatefulWidget {
  const DamagedWalletStoreNotice({super.key});

  @override
  ConsumerState<DamagedWalletStoreNotice> createState() =>
      _DamagedWalletStoreNoticeState();
}

class _DamagedWalletStoreNoticeState
    extends ConsumerState<DamagedWalletStoreNotice> {
  var _busy = false;

  Future<void> _repair() async {
    final settings = ref.read(settingsControllerProvider);
    final repair = ref.read(walletStoreRepairProvider);
    final dir = repair.dataDir(settings);
    final bytes = repair.dbBytes(settings);
    final ok = await confirm(
      context,
      title: 'Move the wallet store aside?',
      message:
          "Floresta's watch-only wallet files in $dir (conf, db, snap.*, "
          'blobs) will be moved into a new "damaged-wallet-store" folder '
          'there. Nothing is deleted, and the blockchain data stays. '
          '${bytes == 0 ? "The store's database file is empty, so it holds no wallet data. " : 'Descriptors the node was watching must be added again in Wallet afterwards. '}'
          'Floresta then starts with a new, empty store.',
      confirmLabel: 'Move aside and start',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final moved = await repair.moveAside(settings);
    if (!mounted) return;
    await moved.match(
      (f) async {
        setState(() => _busy = false);
        showFailure(context, f);
      },
      (m) async {
        showMessage(
          context,
          'Moved ${m.names.join(', ')} to ${m.folder}. Starting Floresta.',
        );
        final started = await ref.read(nodeControllerProvider.notifier).start();
        if (!mounted) return;
        setState(() => _busy = false);
        started.fold((f) => showFailure(context, f), (_) {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final repair = ref.watch(walletStoreRepairProvider);
    final bytes = repair.dbBytes(settings);
    return Notice(
      tone: Tone.danger,
      icon: Icons.error_outline,
      title: "Floresta's wallet store cannot be read",
      message:
          'Floresta stopped while opening its watch-only wallet store in '
          '${repair.dataDir(settings)}. '
          '${bytes == 0 ? 'Its database file is empty, so the store holds no data; it was probably left behind by an interrupted start. ' : 'Its files are damaged. '}'
          'Moving them aside lets Floresta start with a new store; nothing is '
          'deleted.',
      action: DashButton(
        _busy ? 'Working…' : 'Move aside and start',
        style: DashButtonStyle.primary,
        onPressed: _busy ? null : _repair,
      ),
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
