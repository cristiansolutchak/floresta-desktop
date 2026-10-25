import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../domain/node_status.dart';
import '../domain/peer.dart';
import '../domain/sync_progress.dart';
import 'node_controller.dart';
import 'overview_page.dart';
import 'status_labels.dart';
import 'utreexo_peer_controller.dart';

/// Figma "Sync" (frame 1:14673): step card, timeline, explanation,
/// background backfill; then this app's verification details (SYNC-02),
/// which the frame does not have but the honesty rules require.
class SyncPage extends ConsumerWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeControllerProvider);
    final readiness = ref.watch(nodeReadinessProvider);
    return DashPage(
      children: [
        if (readiness.stalledFor case final idle?) ...[
          StalledNotice(status: status, readiness: readiness, idle: idle),
          const SizedBox(height: 16),
        ],
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            DashButton(
              'View Peers',
              height: 32,
              onPressed: () => context.go('/peers'),
            ),
            DashButton(
              'Logs',
              height: 32,
              onPressed: () => context.go('/logs'),
            ),
            DashButton(
              'Refresh',
              height: 32,
              asset: DashIcons.sync,
              style: DashButtonStyle.primary,
              onPressed: ref.read(nodeControllerProvider.notifier).refresh,
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _StepCard(),
        const SizedBox(height: 24),
        const DashColumns(children: [_TimelineCard(), _ExplainCard()]),
        const SizedBox(height: 24),
        const BackfillCard(detailed: true),
        const SizedBox(height: 24),
        _DetailsCard(status),
      ],
    );
  }
}

String _stepSubtitle(SyncStep s) => switch (s) {
  SyncStep.headers => 'Floresta is downloading block headers from its peers.',
  SyncStep.blocks => 'Floresta is currently validating block history.',
  SyncStep.live => 'Floresta is following new blocks as they arrive.',
};

class _StepCard extends ConsumerWidget {
  const _StepCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.dash;
    final p = ref.watch(syncProgressProvider);
    final b = ref.watch(verificationBreakdownProvider);
    final peers = ref.watch(nodeControllerProvider.select((s) => s.peers));
    final ready = peers?.where((x) => x.isReady).toList();
    final counts = ready == null ? null : PeerCounts.of(ready);
    final fraction = p?.fraction;
    final live = p?.step == SyncStep.live;
    final meaning = p == null
        ? 'Needs the node API'
        : fractionMeaning(p, snapshotApplied: b?.snapshotApplied ?? false);

    Widget stat(String label, Widget value) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: DashText.body(context)),
            const SizedBox(height: 2),
            value,
          ],
        ),
      ),
    );
    Widget divider() => VerticalDivider(width: 1, color: t.border);

    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashCardHeader(
            asset: DashIcons.syncingIbd,
            title: p == null
                ? 'Waiting for the node'
                : 'Step ${p.step.number}/${SyncStep.values.length} – '
                      '${p.step.title}',
            subtitle: p == null
                ? 'Sync details appear once the node API is reachable.'
                : _stepSubtitle(p.step),
            trailing: Tooltip(
              message: meaning,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fraction == null ? '—' : formatPercent1(fraction),
                    style: DashText.big(context),
                  ),
                  if (p != null)
                    Text(
                      'Phase ${p.step.phase}',
                      style: DashText.body(context),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (fraction != null)
            DashBar(
              fraction: fraction,
              color: live ? t.successDot : t.warning,
              label: meaning,
            )
          else
            const SizedBox(height: 12),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(border: Border.all(color: t.border)),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  stat(
                    'Current Height',
                    Text(
                      p == null ? '—' : formatInt(p.currentHeight),
                      style: DashText.value(context),
                    ),
                  ),
                  divider(),
                  stat(
                    'Target Height',
                    Text(
                      p == null ? '—' : formatInt(p.targetHeight),
                      style: DashText.value(context),
                    ),
                  ),
                  divider(),
                  stat(
                    'Blocks Behind',
                    Text(
                      p == null ? '—' : behindText(p),
                      style: DashText.value(
                        context,
                        color: (p?.behind ?? 0) > 0 ? t.warningText : null,
                      ),
                    ),
                  ),
                  divider(),
                  stat(
                    'Active Peers',
                    Text.rich(
                      TextSpan(
                        text: counts == null ? '—' : '${counts.total}',
                        style: DashText.value(context),
                        children: [
                          if (counts != null)
                            TextSpan(
                              text: '  (${counts.v2} v2 / ${counts.v1} v1)',
                              style: DashText.body(context),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _StepState { done, current, pending }

class _TimelineCard extends ConsumerWidget {
  const _TimelineCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(syncProgressProvider);
    final chain = ref.watch(nodeControllerProvider.select((s) => s.chain));
    final b = ref.watch(verificationBreakdownProvider);
    _StepState state(SyncStep s) => p == null
        ? _StepState.pending
        : s.index < p.step.index
        ? _StepState.done
        : s == p.step
        ? (s == SyncStep.live ? _StepState.done : _StepState.current)
        : _StepState.pending;

    String text(SyncStep s) {
      final st = state(s);
      return switch (s) {
        SyncStep.headers when st == _StepState.pending =>
          'Starts once the node has peers',
        SyncStep.headers when st == _StepState.done =>
          '${formatInt(chain?.headerHeight ?? 0)} headers downloaded',
        SyncStep.headers =>
          '${formatInt(chain?.headerHeight ?? 0)} of about '
              '${formatInt(p?.targetHeight ?? 0)} headers',
        SyncStep.blocks when st == _StepState.pending =>
          'Starts after the headers',
        SyncStep.blocks when st == _StepState.done =>
          'Verified up to block ${formatInt(chain?.validatedHeight ?? 0)}',
        SyncStep.blocks =>
          '${formatInt(b?.verifiedByNode ?? 0)} blocks verified by this '
              'node, ${behindText(p!)} to go',
        SyncStep.live when st == _StepState.pending =>
          'Follows new blocks once caught up',
        SyncStep.live => 'Following new blocks as they arrive',
      };
    }

    const titles = {
      SyncStep.headers: 'Block Headers',
      SyncStep.blocks: 'Downloading & Verifying Blocks',
      SyncStep.live: 'Live Catch-up',
    };

    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DashCardHeader(icon: Icons.schedule, title: 'Sync Timeline'),
          const SizedBox(height: 24),
          for (final s in SyncStep.values)
            _TimelineStep(
              title: titles[s]!,
              text: text(s),
              state: state(s),
              last: s == SyncStep.values.last,
            ),
        ],
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.title,
    required this.text,
    required this.state,
    required this.last,
  });
  final String title;
  final String text;
  final _StepState state;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final icon = switch (state) {
      _StepState.done => Icon(
        Icons.check_circle_outline,
        size: 24,
        color: t.successDot,
      ),
      _StepState.current => Icon(Icons.timelapse, size: 24, color: t.warning),
      _StepState.pending => Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: t.subtle,
          border: Border.all(color: t.border),
        ),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: t.border),
        ),
      ),
    };
    final label = switch (state) {
      _StepState.done => 'done',
      _StepState.current => 'in progress',
      _StepState.pending => 'not started',
    };
    return Semantics(
      label: '$title, $label: $text',
      excludeSemantics: true,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                icon,
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: t.border,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: last ? 0 : 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: DashText.body(
                        context,
                        color: state == _StepState.pending
                            ? t.textMuted
                            : t.textPrimary,
                        weight: FontWeight.w500,
                      ),
                    ),
                    Text(text, style: DashText.body(context)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplainCard extends StatelessWidget {
  const _ExplainCard();

  @override
  Widget build(BuildContext context) {
    return DashCard(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const DashIconBlock(Icons.memory, size: 40, iconSize: 24),
          const SizedBox(height: 16),
          Semantics(
            header: true,
            child: Text(
              'What is happening?',
              style: DashText.cardTitle(context).copyWith(fontSize: 16),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Floresta is a Utreexo-powered node. It downloads block headers '
            'first, then verifies block data without storing the entire '
            'chain history.',
            textAlign: TextAlign.center,
            style: DashText.body(context),
          ),
          const SizedBox(height: 8),
          Text(
            'It checks Bitcoin rules cryptographically as it downloads data, '
            'ensuring you don\'t need to trust third parties.',
            textAlign: TextAlign.center,
            style: DashText.body(context),
          ),
        ],
      ),
    );
  }
}

/// What this node checked itself versus accepted from the snapshot, peers
/// that serve proofs, and the chain facts the node reports (SYNC-02/03/05).
class _DetailsCard extends ConsumerWidget {
  const _DetailsCard(this.status);
  final NodeStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readiness = ref.watch(nodeReadinessProvider);
    final search = ref.watch(utreexoPeerSearchProvider);
    final b = ref.watch(verificationBreakdownProvider);
    final chain = status.chain;
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DashCardHeader(
            icon: Icons.fact_check_outlined,
            title: 'Verification details',
            subtitle:
                'What this node checked itself, and what it accepted from '
                'the snapshot.',
          ),
          const SizedBox(height: 16),
          if (chain == null)
            const EmptyState(
              icon: Icons.sync_disabled,
              title: 'No chain data yet',
              message:
                  'Sync details appear here once the node API is '
                  'reachable.',
            )
          else ...[
            DashDetailRow('Block headers known', formatInt(chain.headerHeight)),
            // SYNC-03: peers' heights are from when they connected, so this
            // is an estimate and says so.
            if (readiness.peerTip case final tip?
                when tip > chain.validatedHeight)
              DashDetailRow(
                'Network tip (estimate from peers)',
                '${formatInt(tip)} · about '
                    '${formatInt(tip - chain.validatedHeight)} blocks left to verify',
              ),
            if (readiness.snapshotHeight > 0 || search.lastAttempt != null)
              DashDetailRow('Utreexo peers', () {
                final connected = (status.peers ?? const [])
                    .where((p) => p.isReady && p.supportsUtreexo)
                    .toList();
                final verified = connected
                    .where((p) => search.added.contains(p.address))
                    .length;
                return '${connected.length} connected, $verified verified by '
                    'the app (2 verified wanted)';
              }()),
            if (search.restarts.isNotEmpty)
              DashDetailRow(
                'Automatic restarts',
                '${search.restarts.length}: Floresta had all headers but did '
                    'not start verifying (a known Floresta 0.9.1 stall)',
              ),
            if (status.disk case final disk?)
              DashDetailRow(
                'Data folder',
                [
                  if (disk.usedBytes case final u?) '${formatBytes(u)} used',
                  if (disk.freeBytes case final f?) '${formatBytes(f)} free',
                ].join(' · '),
              ),
            DashDetailRow(
              'Verified by this node',
              b == null
                  ? 'Block ${formatInt(chain.validatedHeight)} (network unknown)'
                  : b.verifiedByNode == 0
                  ? 'None yet'
                  : 'Blocks ${formatInt(b.acceptedUpTo + 1)} to '
                        '${formatInt(chain.validatedHeight)} '
                        '(${formatInt(b.verifiedByNode)})',
            ),
            if (b != null && b.snapshotApplied)
              DashDetailRow(
                'Accepted from snapshot',
                'Blocks 0 to ${formatInt(b.acceptedUpTo)}: the Utreexo state '
                    'built into Floresta, not yet re-checked here. Floresta '
                    're-checks it in the background; version 0.9.1 does not '
                    'report that progress.',
              )
            else if (b != null && b.snapshotHeight > 0 && b.verifiedByNode == 0)
              DashDetailRow(
                'Snapshot',
                'Will be used at block ${formatInt(b.snapshotHeight)} once '
                    'the headers reach it.',
              ),
            if (b != null && b.scriptsSkippedUpTo > 0)
              DashDetailRow(
                'Signature checks',
                'Skipped up to block ${formatInt(b.scriptsSkippedUpTo)} '
                    '(assume-valid, as in Bitcoin Core)',
              ),
            DashDetailRow(
              'Initial block download',
              chain.initialBlockDownload ? 'In progress' : 'Complete',
            ),
            DashDetailRow('Latest block time', _formatTime(chain.tipTime)),
            DashDetailRow('Best block hash', chain.bestBlockHash, mono: true),
            if (chain.utreexoLeaves case final leaves? when leaves > 0)
              DashDetailRow(
                'Utreexo accumulator',
                '${formatInt(leaves)} outputs in '
                    '${chain.utreexoRoots ?? '?'} roots',
              ),
            if (chain.sizeOnDisk case final size?)
              DashDetailRow('Chain state on disk', formatBytes(size)),
            if (chain.network == null)
              DashDetailRow('Reported chain', chain.chain),
            for (final w in chain.warnings) ...[
              const SizedBox(height: 8),
              Notice(tone: Tone.warning, title: 'Node warning', message: w),
            ],
          ],
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
