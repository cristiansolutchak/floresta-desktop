import 'package:floresta_gui/features/node/data/rpc_models.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/domain/peer.dart';
import 'package:floresta_gui/features/node/domain/sync_progress.dart';
import 'package:floresta_gui/features/node/domain/verification_breakdown.dart';
import 'package:floresta_gui/features/node/presentation/status_labels.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/shared/format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'node_rpc_test.dart' show signetAfterSnapshot;

Peer _peer(int id, {bool inbound = false, String transport = 'V2'}) => Peer(
  id: id,
  address: '10.0.0.$id:38333',
  userAgent: '/Satoshi:30.0.0/',
  inbound: inbound,
  kind: 'regular',
  state: 'Ready',
  transport: transport,
  initialHeight: 0,
  services: const [],
);

void main() {
  final chain = RpcModels.blockchainInfo(signetAfterSnapshot);
  final breakdown = VerificationBreakdown.of(
    chain,
    BitcoinNetwork.signet,
    snapshotHeight: 296870,
  );

  group('SyncProgress', () {
    test('verifying blocks: own verification after the snapshot only', () {
      final p = SyncProgress.of(
        chain,
        const NodeReadiness(ReadinessStage.validatingBlocks, peerTip: 327900),
        breakdown,
      );
      expect(p.step, SyncStep.blocks);
      expect(p.fraction, 0); // not florestad's 0.9056
      expect(p.currentHeight, 296870);
      expect(p.targetHeight, 327900);
      expect(p.behind, 31030);
      expect(p.tipIsEstimate, isTrue);
    });

    test('headers with no peer tip: no fraction, no behind, tip unknown', () {
      // Just after a restart no peer is connected; the node's own headers
      // must not become the target (it showed "100 %", 2026-10-28).
      final fresh = RpcModels.blockchainInfo({
        ...signetAfterSnapshot,
        'validated': 0,
        'height': 16000,
      });
      final p = SyncProgress.of(
        fresh,
        const NodeReadiness(ReadinessStage.downloadingHeaders),
        null,
      );
      expect(p.step, SyncStep.headers);
      expect(p.tipKnown, isFalse);
      expect(p.fraction, isNull);
      expect(p.behind, 0);
      expect(p.leadingStat.value, 16000);
    });

    test('headers with a peer tip: fraction of that tip', () {
      final p = SyncProgress.of(
        chain,
        const NodeReadiness(ReadinessStage.downloadingHeaders, peerTip: 655686),
        breakdown,
      );
      expect(p.step, SyncStep.headers);
      expect(p.tipKnown, isTrue);
      expect(p.fraction, 0.5);
      expect(p.targetHeight, 655686);
    });

    test('after the headers, no peer tip means the headers are the target', () {
      final p = SyncProgress.of(
        chain,
        const NodeReadiness(ReadinessStage.validatingBlocks),
        breakdown,
      );
      expect(p.step, SyncStep.blocks);
      expect(p.tipKnown, isTrue);
      expect(p.targetHeight, 327843);
      expect(p.tipIsEstimate, isFalse);
    });

    test('nothing validated yet is still the headers step', () {
      final fresh = RpcModels.blockchainInfo({
        ...signetAfterSnapshot,
        'validated': 0,
        'height': 1000,
      });
      final p = SyncProgress.of(
        fresh,
        const NodeReadiness(ReadinessStage.validatingBlocks, peerTip: 4000),
        null,
      );
      expect(p.step, SyncStep.headers);
      expect(p.fraction, 0.25);
    });

    test('the first stat is the header count while headers download', () {
      final fresh = RpcModels.blockchainInfo({
        ...signetAfterSnapshot,
        'validated': 0,
        'height': 24000,
      });
      final headers = SyncProgress.of(
        fresh,
        const NodeReadiness(ReadinessStage.downloadingHeaders, peerTip: 973490),
        null,
      );
      // 0 validated next to 2.5 % is what confused users (2026-10-28).
      expect(headers.currentHeight, 0);
      expect(headers.leadingStat, (label: 'Headers Downloaded', value: 24000));

      final blocks = SyncProgress.of(
        chain,
        const NodeReadiness(ReadinessStage.validatingBlocks, peerTip: 327900),
        breakdown,
      );
      expect(blocks.leadingStat, (label: 'Current Height', value: 296870));
    });

    test('the fraction is against the network tip, not own headers', () {
      final behind = RpcModels.blockchainInfo({
        ...signetAfterSnapshot,
        'height': 310000,
        'validated': 305000,
      });
      final b = VerificationBreakdown.of(
        behind,
        BitcoinNetwork.signet,
        snapshotHeight: 296870,
      );
      final p = SyncProgress.of(
        behind,
        const NodeReadiness(ReadinessStage.validatingBlocks, peerTip: 327900),
        b,
      );
      // 8 130 verified of 31 030 to the tip; by headers it would be 62 %.
      expect(p.fraction, closeTo(8130 / 31030, 1e-9));
    });

    test('headers stuck below the peers are the headers step', () {
      final p = SyncProgress.of(
        RpcModels.blockchainInfo({
          ...signetAfterSnapshot,
          'height': 200000,
          'validated': 200000,
        }),
        const NodeReadiness(ReadinessStage.behindNetwork, peerTip: 400000),
        null,
      );
      expect(p.step, SyncStep.headers);
      expect(p.fraction, 0.5);
    });

    test('ready is live at 100 %', () {
      final p = SyncProgress.of(
        chain,
        const NodeReadiness(ReadinessStage.ready),
        breakdown,
      );
      expect(p.step, SyncStep.live);
      expect(p.fraction, 1);
    });
  });

  test('PeerCounts splits direction and transport', () {
    final c = PeerCounts.of([
      _peer(1),
      _peer(2, inbound: true, transport: 'V1'),
      _peer(3, transport: 'V1'),
    ]);
    expect((c.total, c.inbound, c.outbound, c.v1, c.v2), (3, 1, 2, 2, 1));
  });

  group('StatusLabels.short', () {
    test('stopped node', () {
      const s = NodeStatus(api: ApiReachability.unreachable);
      expect(
        StatusLabels.short(
          const NodeReadiness(ReadinessStage.stopped),
          s,
        ).label,
        'Stopped',
      );
    });

    test('our process up, API not yet', () {
      final s = NodeStatus(
        process: ProcessRunning(1, DateTime(2026)),
        api: ApiReachability.unreachable,
      );
      expect(
        StatusLabels.short(
          const NodeReadiness(ReadinessStage.starting),
          s,
        ).label,
        'Starting',
      );
    });

    test('syncing, stalled and synced', () {
      const s = NodeStatus(api: ApiReachability.reachable);
      expect(
        StatusLabels.short(
          const NodeReadiness(ReadinessStage.validatingBlocks),
          s,
        ).label,
        'Syncing',
      );
      expect(
        StatusLabels.short(
          const NodeReadiness(
            ReadinessStage.validatingBlocks,
            stalledFor: Duration(minutes: 30),
          ),
          s,
        ).label,
        'Stalled',
      );
      expect(
        StatusLabels.short(const NodeReadiness(ReadinessStage.ready), s).label,
        'Synced',
      );
    });
  });

  test('formatCompact', () {
    expect(formatCompact(999), '999');
    expect(formatCompact(14444), '14.4k');
    expect(formatCompact(250000), '250k');
    expect(formatCompact(1200000), '1.2M');
  });
}
