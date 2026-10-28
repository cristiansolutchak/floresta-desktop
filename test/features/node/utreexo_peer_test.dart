import 'dart:typed_data';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/features/node/data/p2p_version_probe.dart';
import 'package:floresta_gui/features/node/data/utreexo_peer_finder.dart';
import 'package:floresta_gui/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_gui/features/node/domain/utreexo_peer.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';

import '../../helpers/fakes.dart';

const _utreexod = PeerProbe(
  protocolVersion: 70016,
  services: 0x340d, // observed from 161.97.178.61:8333 on 2026-10-25
  userAgent: '/btcwire:0.5.0/utreexod:0.5.2/',
  height: 970486,
);
const _core = PeerProbe(
  protocolVersion: 70016,
  services: 0xc49,
  userAgent: '/Satoshi:31.1.0/',
  height: 973046,
);

void main() {
  group('judgeUtreexoCandidate', () {
    test(
      'a node behind the tip is usable for the blocks it has (observed)',
      () {
        // utreexod at 970 486 while the tip was 973 099 and we had validated
        // only up to the snapshot: it served the proofs that unblocked mainnet.
        expect(
          judgeUtreexoCandidate(
            _utreexod,
            network: BitcoinNetwork.bitcoin,
            validatedHeight: 939969,
          ),
          UtreexoCandidateVerdict.usable,
        );
      },
    );

    test('a behind Utreexo node waits until chain selection is over', () {
      // It ignores getheaders while behind, which holds selection forever.
      expect(
        judgeUtreexoCandidate(
          _utreexod,
          network: BitcoinNetwork.bitcoin,
          validatedHeight: 940045,
          inSelection: true,
          consensusTip: 973511,
        ),
        UtreexoCandidateVerdict.behindDuringSelection,
      );
      expect(
        judgeUtreexoCandidate(
          _utreexod,
          network: BitcoinNetwork.bitcoin,
          validatedHeight: 940045,
          consensusTip: 973511,
        ),
        UtreexoCandidateVerdict.usable,
      );
      // Close to the tip it answers getheaders, so it can be added anytime.
      expect(
        judgeUtreexoCandidate(
          _utreexod,
          network: BitcoinNetwork.bitcoin,
          inSelection: true,
          consensusTip: 970500,
        ),
        UtreexoCandidateVerdict.usable,
      );
    });

    test('a Utreexo node past the snapshot is usable', () {
      expect(
        judgeUtreexoCandidate(_utreexod, network: BitcoinNetwork.bitcoin),
        UtreexoCandidateVerdict.usable,
      );
      expect(_utreexod.servesUtreexo, isTrue);
    });

    test('rejects non-Utreexo, stale and unreachable nodes', () {
      expect(
        judgeUtreexoCandidate(_core, network: BitcoinNetwork.bitcoin),
        UtreexoCandidateVerdict.notUtreexo,
      );
      expect(
        judgeUtreexoCandidate(
          const PeerProbe(
            protocolVersion: 70016,
            services: nodeUtreexoBit,
            userAgent: '/old/',
            height: 939000, // before the mainnet snapshot (939 969)
          ),
          network: BitcoinNetwork.bitcoin,
        ),
        UtreexoCandidateVerdict.tooFarBehind,
      );
      expect(
        judgeUtreexoCandidate(
          _utreexod, // 970 486
          network: BitcoinNetwork.bitcoin,
          validatedHeight: 970400, // it has almost nothing we still need
        ),
        UtreexoCandidateVerdict.tooFarBehind,
      );
      expect(
        judgeUtreexoCandidate(
          const PeerProbe.failed('no answer'),
          network: BitcoinNetwork.bitcoin,
        ),
        UtreexoCandidateVerdict.unreachable,
      );
    });
  });

  group('shouldSeekUtreexoPeers', () {
    final now = DateTime(2026, 10, 25, 12);
    bool seek({
      bool own = true,
      BitcoinNetwork network = BitcoinNetwork.bitcoin,
      int peers = 8,
      int utreexo = 0,
      DateTime? last,
    }) => shouldSeekUtreexoPeers(
      ownNode: own,
      network: network,
      connectedPeers: peers,
      utreexoPeers: utreexo,
      now: now,
      lastAttempt: last,
    );

    test('seeks for our node while it has fewer than 2 Utreexo peers', () {
      expect(seek(), isTrue);
      expect(seek(utreexo: 1), isTrue);
      expect(seek(utreexo: 2), isFalse);
    });

    test('never for a node we did not start, with no peers, or on regtest', () {
      expect(seek(own: false), isFalse);
      expect(seek(peers: 0), isFalse);
      expect(seek(network: BitcoinNetwork.regtest), isFalse);
    });

    test('at most once every two minutes', () {
      expect(seek(last: now.subtract(const Duration(seconds: 90))), isFalse);
      expect(seek(last: now.subtract(const Duration(minutes: 2))), isTrue);
    });
  });

  group('stalledUtreexoPeersToDrop', () {
    const bridge = (address: '189.44.63.101:8333', utreexo: true);
    const utreexod = (address: '161.97.178.61:8333', utreexo: true);
    const core = (address: '195.26.240.213:8333', utreexo: false);
    const verified = {'161.97.178.61:8333'};

    test('drops unverified Utreexo peers once validation stalls', () {
      expect(
        stalledUtreexoPeersToDrop(
          connected: [bridge, utreexod, core],
          verified: verified,
          stalledFor: const Duration(minutes: 4),
        ),
        ['189.44.63.101:8333'],
      );
    });

    test('keeps everyone while progressing or with no verified peer', () {
      expect(
        stalledUtreexoPeersToDrop(
          connected: [bridge, utreexod],
          verified: verified,
          stalledFor: const Duration(minutes: 1),
        ),
        isEmpty,
      );
      expect(
        stalledUtreexoPeersToDrop(
          connected: [bridge, core],
          verified: verified,
          stalledFor: const Duration(minutes: 10),
        ),
        isEmpty,
        reason: 'nobody verified would take over',
      );
    });
  });

  group('chain selection phase', () {
    // florestad v0.9.1 lines, from the mainnet debug.log of 2026-10-28.
    const start =
        '2026-10-28 03:21:07  INFO floresta_wire::p2p_wire::node::'
        'chain_selector_ctx: Starting IBD, selecting the best chain';
    const headers =
        '2026-10-28 03:22:20  INFO floresta_wire::p2p_wire::node::'
        'chain_selector_ctx: Downloading headers from peer=10 at height=973512';
    const assumed =
        '2026-10-28 03:08:21  INFO floresta_wire::p2p_wire::node::'
        'chain_selector_ctx: Assuming chain with height=939969 tip=0000';
    const sync =
        '2026-10-28 03:08:27  INFO floresta_wire::p2p_wire::node::sync_ctx: '
        'Starting sync node...';

    test('from the node output: the last start decides', () {
      expect(selectionPhaseFromLogs(const []), SelectionPhase.unknown);
      expect(selectionPhaseFromLogs([headers]), SelectionPhase.unknown);
      expect(
        selectionPhaseFromLogs([start, headers]),
        SelectionPhase.selecting,
      );
      expect(
        selectionPhaseFromLogs([start, assumed, sync]),
        SelectionPhase.done,
      );
      // A restart: the previous run's end does not count.
      expect(
        selectionPhaseFromLogs([start, sync, start, headers]),
        SelectionPhase.selecting,
      );
      expect(
        selectionPhaseFromLogs([
          start,
          '… INFO floresta_wire::p2p_wire::node::running_ctx: '
              'Catching up with the network...',
        ]),
        SelectionPhase.done,
      );
    });

    bool fallback({
      int validated = 940045,
      int? atStart = 940045,
      int headers = 973512,
      int? tip = 973511,
    }) => inChainSelection(
      logged: SelectionPhase.unknown,
      validatedHeight: validated,
      validatedAtStart: atStart,
      headerHeight: headers,
      peerTip: tip,
    );

    test('without output: headers in, nothing validated since start', () {
      // The observed case: an earlier run had validated 940 045.
      expect(fallback(), isTrue);
      expect(fallback(validated: 940046), isFalse); // validation resumed
      expect(fallback(headers: 960000), isFalse); // headers still coming
      expect(fallback(atStart: null), isFalse); // no process seen
      expect(fallback(tip: null), isFalse);
      // A synced node restarted has nothing to validate: not "stuck".
      expect(fallback(validated: 973510, atStart: 973510), isFalse);
    });

    test('the node output wins over the fallback', () {
      bool logged(SelectionPhase p) => inChainSelection(
        logged: p,
        validatedHeight: 940046,
        validatedAtStart: 940045,
        headerHeight: 973512,
        peerTip: 973511,
      );
      expect(logged(SelectionPhase.selecting), isTrue);
      expect(logged(SelectionPhase.done), isFalse);
    });
  });

  group('StuckSelectionTracker (SYNC-09)', () {
    final t0 = DateTime(2026, 10, 25, 10, 39);
    bool sample(
      StuckSelectionTracker t,
      Duration at, {
      bool selecting = true,
      int headers = 973075,
      int? tip = 973075,
      bool own = true,
      int snapshot = 939969,
      int blocking = 0,
    }) => t.sample(
      ownNode: own,
      snapshotHeight: snapshot,
      inSelection: selecting,
      headerHeight: headers,
      peerTip: tip,
      now: t0.add(at),
      blockingPeers: blocking,
    );

    test('restarts after 5 min with all headers and nothing validated, '
        'even while new headers keep arriving (observed case)', () {
      final t = StuckSelectionTracker();
      expect(sample(t, Duration.zero), isFalse);
      expect(
        sample(t, const Duration(minutes: 3), headers: 973077, tip: 973077),
        isFalse,
      );
      expect(
        sample(t, const Duration(minutes: 5), headers: 973078, tip: 973078),
        isTrue,
      );
      expect(t.restarts, hasLength(1));
    });

    test('never while downloading headers or once selection is over', () {
      final t = StuckSelectionTracker();
      expect(sample(t, Duration.zero, headers: 600000), isFalse);
      expect(sample(t, const Duration(minutes: 10), headers: 600000), isFalse);
      expect(sample(t, const Duration(minutes: 11)), isFalse); // window starts
      expect(sample(t, const Duration(minutes: 20), selecting: false), isFalse);
      expect(sample(t, const Duration(minutes: 30), own: false), isFalse);
      expect(sample(t, const Duration(minutes: 40), snapshot: 0), isFalse);
    });

    test('drops come first: no restart while a blocking peer is there', () {
      final t = StuckSelectionTracker();
      expect(sample(t, Duration.zero), isFalse);
      // The app drops the behind utreexod at 4 min: the window starts over.
      expect(sample(t, const Duration(minutes: 4), blocking: 1), isFalse);
      expect(sample(t, const Duration(minutes: 6)), isFalse);
      // Still stuck 5 min after the drop, with nobody left to drop: restart.
      expect(sample(t, const Duration(minutes: 9)), isTrue);
    });

    test('at most 3 restarts, 15 minutes apart', () {
      final t = StuckSelectionTracker();
      var restarts = 0;
      for (var m = 0; m <= 120; m++) {
        if (sample(t, Duration(minutes: m))) restarts++;
      }
      expect(restarts, 3);
      expect(
        t.restarts[1].difference(t.restarts[0]).inMinutes,
        greaterThanOrEqualTo(15),
      );
    });
  });

  group('forkPeersToDrop (SYNC-10)', () {
    final peers = [
      for (var i = 0; i < 9; i++) (address: 'core$i:8333', height: 973080),
      (address: '176.132.253.23:8333', height: 978945),
      (address: '62.99.98.60:8333', height: 961639),
    ];
    List<String> drop({int headers = 973087, bool selecting = true}) =>
        forkPeersToDrop(
          peers: peers,
          consensusTip: 973080,
          headerHeight: headers,
          inSelection: selecting,
          snapshotHeight: 939969,
        );

    test('drops peers far above or below the consensus (both observed)', () {
      expect(drop(), ['176.132.253.23:8333', '62.99.98.60:8333']);
    });

    test('leaves peers alone while headers download or after selection', () {
      expect(drop(headers: 600000), isEmpty);
      expect(drop(selecting: false), isEmpty);
    });

    test('drops a behind utreexod in selection, after blocks were validated '
        '(mainnet 2026-10-28)', () {
      // Validated 940 045 in an earlier run; after the restart the
      // utreexod at 970 486 ignored getheaders and selection never ended.
      expect(
        forkPeersToDrop(
          peers: [
            for (var i = 0; i < 9; i++)
              (address: 'core$i:8333', height: 973511),
            (address: '161.97.178.61:8333', height: 970486),
          ],
          consensusTip: 973511,
          headerHeight: 973512,
          inSelection: true,
          snapshotHeight: 939969,
        ),
        ['161.97.178.61:8333'],
      );
    });
  });

  group('P2pVersionProbe wire format', () {
    test('a version message has the network magic and a valid header', () {
      final m = P2pVersionProbe.versionMessage(BitcoinNetwork.signet, nonce: 7);
      expect(m.sublist(0, 4), [0x0a, 0x03, 0xcf, 0x40]);
      expect(String.fromCharCodes(m.sublist(4, 11)), 'version');
      final length = ByteData.sublistView(m).getUint32(16, Endian.little);
      expect(m.length, 24 + length);
    });

    test('parses a peer version reply and its Utreexo bit', () {
      // Build a reply with our own encoder, then patch services and height.
      final reply = P2pVersionProbe.versionMessage(BitcoinNetwork.bitcoin);
      final d = ByteData.sublistView(reply);
      d.setUint64(24 + 4, 0x340d, Endian.little);
      final ua = '/floresta-gui-probe:0.1/'.length;
      d.setInt32(24 + 4 + 8 + 8 + 26 + 26 + 8 + 1 + ua, 970486, Endian.little);
      final p = P2pVersionProbe.parseVersionReply(
        reply,
        BitcoinNetwork.bitcoin,
      )!;
      expect(p.servesUtreexo, isTrue);
      expect(p.height, 970486);
      expect(
        P2pVersionProbe.parseVersionReply(
          reply.sublist(0, 30),
          BitcoinNetwork.bitcoin,
        ),
        isNull,
        reason: 'incomplete: needs more bytes',
      );
      expect(
        P2pVersionProbe.parseVersionReply(reply, BitcoinNetwork.signet)!.error,
        contains('another network'),
      );
    });

    test('malformed replies are rejected, never thrown', () {
      // A header announcing a 10-byte version payload.
      final tiny = P2pVersionProbe.frame(
        BitcoinNetwork.bitcoin,
        'version',
        List.filled(10, 0),
      );
      expect(
        P2pVersionProbe.parseVersionReply(tiny, BitcoinNetwork.bitcoin)!.error,
        contains('malformed'),
      );
      // A user-agent length pointing past the end of the payload.
      final bad = P2pVersionProbe.versionMessage(BitcoinNetwork.bitcoin);
      ByteData.sublistView(bad).setUint8(24 + 80, 200);
      expect(
        P2pVersionProbe.parseVersionReply(bad, BitcoinNetwork.bitcoin)!.error,
        contains('malformed'),
      );
    });
  });

  group('UtreexoPeerFinder', () {
    test(
      'adds only verified Utreexo nodes, skips v2-only and the rest',
      () async {
        final rpc = FakeNodeRpcRepository();
        final probes = <String, PeerProbe>{
          '161.97.178.61': _utreexod,
          '189.44.63.101': const PeerProbe.failed(noVersionReply),
          '195.26.240.213': _core,
          '1.228.21.110': const PeerProbe.failed('Connection timed out'),
        };
        final finder = UtreexoPeerFinder(
          rpc: rpc,
          resolve: (host) async {
            expect(host, 'x1000.bitcoin.seed.dlsouza.lol');
            return ['189.44.63.101', '195.26.240.213', '1.228.21.110'];
          },
          probe: (host, port, network) async {
            expect(port, 8333);
            return probes[host]!;
          },
        );
        final attempts = await finder.run(BitcoinNetwork.bitcoin);
        expect(attempts.map((a) => (a.address, a.action)), [
          ('189.44.63.101:8333', null), // v2-only: never added
          ('195.26.240.213:8333', null),
          ('1.228.21.110:8333', null),
          ('161.97.178.61:8333', 'add'), // curated, verified again here
        ]);
        expect(rpc.addNodeCalls, [
          ('161.97.178.61:8333', AddNodeCommand.add, false),
        ]);
      },
    );

    test(
      'holds a behind utreexod back during selection, adds it after',
      () async {
        final rpc = FakeNodeRpcRepository();
        final finder = UtreexoPeerFinder(
          rpc: rpc,
          resolve: (_) async => const [],
          probe: (_, _, _) async => _utreexod,
        );
        final held = await finder.run(
          BitcoinNetwork.bitcoin,
          validatedHeight: 940045,
          inSelection: true,
          consensusTip: 973511,
        );
        expect(held.single.action, isNull);
        expect(rpc.addNodeCalls, isEmpty);

        final later = await finder.run(
          BitcoinNetwork.bitcoin,
          validatedHeight: 940045,
          consensusTip: 973511,
        );
        expect(later.single.action, 'add');
      },
    );

    test(
      'a peer the app added is taken off the reconnect list first',
      () async {
        final calls = <String>[];
        final rpc = _RecordingRpc(calls);
        await dropPeer(rpc, '161.97.178.61:8333', addedByApp: true);
        await dropPeer(rpc, '62.99.98.60:8333', addedByApp: false);
        expect(calls, [
          'remove 161.97.178.61:8333',
          'disconnect 161.97.178.61:8333',
          'disconnect 62.99.98.60:8333',
        ]);
      },
    );

    test('does not re-add peers the node already has', () async {
      final rpc = FakeNodeRpcRepository();
      final finder = UtreexoPeerFinder(
        rpc: rpc,
        resolve: (_) async => const [],
        probe: (_, _, _) async => _utreexod,
      );
      final attempts = await finder.run(
        BitcoinNetwork.bitcoin,
        alreadyConnected: {'161.97.178.61:8333'},
      );
      expect(attempts, isEmpty);
      expect(rpc.addNodeCalls, isEmpty);
    });
  });
}

/// Records the order of addnode/disconnectnode calls.
class _RecordingRpc extends FakeNodeRpcRepository {
  _RecordingRpc(this.calls);
  final List<String> calls;

  @override
  Future<Either<Failure, Unit>> addNode(
    String address, {
    required AddNodeCommand command,
    bool v2transport = false,
  }) async {
    calls.add('${command.name} $address');
    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> disconnectNode(String address) async {
    calls.add('disconnect $address');
    return const Right(unit);
  }
}
