import 'dart:typed_data';

import 'package:floresta_gui/features/node/data/p2p_version_probe.dart';
import 'package:floresta_gui/features/node/data/utreexo_peer_finder.dart';
import 'package:floresta_gui/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_gui/features/node/domain/utreexo_peer.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';

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
          _utreexod,
          network: BitcoinNetwork.bitcoin,
          networkTip: 980000, // more than 2016 blocks ahead
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

  group('StuckSelectionTracker (SYNC-09)', () {
    final t0 = DateTime(2026, 10, 25, 10, 39);
    bool sample(
      StuckSelectionTracker t,
      Duration at, {
      int validated = 0,
      int headers = 973075,
      int? tip = 973075,
      bool own = true,
      int snapshot = 939969,
    }) => t.sample(
      ownNode: own,
      snapshotHeight: snapshot,
      validatedHeight: validated,
      headerHeight: headers,
      peerTip: tip,
      now: t0.add(at),
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

    test('never while downloading headers or once validation runs', () {
      final t = StuckSelectionTracker();
      expect(sample(t, Duration.zero, headers: 600000), isFalse);
      expect(sample(t, const Duration(minutes: 10), headers: 600000), isFalse);
      expect(sample(t, const Duration(minutes: 11)), isFalse); // window starts
      expect(
        sample(t, const Duration(minutes: 20), validated: 939970),
        isFalse,
      );
      expect(sample(t, const Duration(minutes: 30), own: false), isFalse);
      expect(sample(t, const Duration(minutes: 40), snapshot: 0), isFalse);
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
