import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/domain/peer.dart';
import 'package:floresta_gui/features/node/presentation/status_labels.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 24, 22);

BlockchainInfo _chain({
  required int headers,
  required int validated,
  required bool ibd,
  BitcoinNetwork network = BitcoinNetwork.signet,
}) => BlockchainInfo(
  chain: network.cliValue,
  network: network,
  validatedHeight: validated,
  headerHeight: headers,
  bestBlockHash: '00',
  verificationProgress: 0,
  initialBlockDownload: ibd,
  tipTime: DateTime.utc(2026),
  sizeOnDisk: null,
  warnings: const [],
);

Peer _peer({bool utreexo = false, int initialHeight = 327831}) => Peer(
  id: 1,
  address: '1.2.3.4:38333',
  userAgent: '/Satoshi:30.0.0/',
  inbound: false,
  kind: 'regular',
  state: 'Ready',
  transport: 'V2',
  initialHeight: initialHeight,
  services: ['NETWORK', 'WITNESS', if (utreexo) 'UTREEXO'],
);

NodeStatus _status({
  BlockchainInfo? chain,
  List<Peer> peers = const [],
  DateTime? progressAt,
  ElectrumCheck electrum = ElectrumCheck.unknown,
}) => NodeStatus(
  process: ProcessRunning(1, _now),
  api: chain == null ? ApiReachability.unreachable : ApiReachability.reachable,
  chain: chain,
  peers: peers,
  lastProgressAt: progressAt ?? _now,
  electrum: electrum,
);

NodeReadiness _assess(NodeStatus s, {bool logged = false}) => assessReadiness(
  s,
  expected: BitcoinNetwork.signet,
  now: _now,
  noUtreexoPeersLogged: logged,
);

void main() {
  // Stages observed on a real signet florestad v0.9.1 (2026-10-24).
  test('process up, API not yet', () {
    expect(_assess(_status()).stage, ReadinessStage.starting);
    expect(_assess(const NodeStatus()).stage, ReadinessStage.stopped);
  });

  test('t=5 s: API up, no peers, no headers', () {
    final r = _assess(
      _status(chain: _chain(headers: 0, validated: 0, ibd: true)),
    );
    expect(r.stage, ReadinessStage.findingPeers);
  });

  test('t=90 s .. 240 s: headers counting up, nothing validated', () {
    final r = _assess(
      _status(
        chain: _chain(headers: 192000, validated: 0, ibd: true),
        peers: [_peer()],
      ),
    );
    expect(r.stage, ReadinessStage.downloadingHeaders);
  });

  test('after the assumed state: validating, blocked on Utreexo peers', () {
    final s = _status(
      chain: _chain(headers: 327831, validated: 296870, ibd: true),
      peers: [_peer(), _peer()],
      progressAt: _now.subtract(const Duration(minutes: 12)),
    );
    final r = _assess(s);
    expect(r.stage, ReadinessStage.validatingBlocks);
    expect(r.missingUtreexoPeers, isTrue);
    expect(r.stalledFor, const Duration(minutes: 12));
    final label = StatusLabels.readiness(r, s);
    expect(label.label, 'Waiting for Utreexo peers (no progress)');
  });

  test('one Utreexo peer is not enough (florestad wants 2)', () {
    // Mainnet, 2026-10-25: 0–1 Utreexo peers, no progress past 939,969.
    final one = _status(
      chain: _chain(headers: 973011, validated: 939969, ibd: true),
      peers: [_peer(utreexo: true), _peer()],
    );
    expect(_assess(one).missingUtreexoPeers, isTrue);
    final two = _status(
      chain: _chain(headers: 973011, validated: 939969, ibd: true),
      peers: [_peer(utreexo: true), _peer(utreexo: true)],
    );
    expect(_assess(two).missingUtreexoPeers, isFalse);
    expect(_assess(two, logged: true).missingUtreexoPeers, isTrue);
  });

  test('ready only when synced; usable only with Electrum confirmed', () {
    final synced = _chain(headers: 327900, validated: 327900, ibd: false);
    final r = _assess(_status(chain: synced, electrum: ElectrumCheck.ok));
    expect(r.stage, ReadinessStage.ready);
    expect(r.usable, isTrue);
    expect(
      _assess(
        _status(chain: synced, electrum: ElectrumCheck.unreachable),
      ).usable,
      isFalse,
    );
  });

  test('a node on another network is flagged', () {
    final r = _assess(
      _status(
        chain: _chain(
          headers: 10,
          validated: 10,
          ibd: false,
          network: BitcoinNetwork.regtest,
        ),
        electrum: ElectrumCheck.ok,
      ),
    );
    expect(r.wrongNetwork, isTrue);
    expect(r.usable, isFalse);
  });

  test('the log signal matches v0.9.1 wording only', () {
    expect(
      logsShowNoUtreexoPeers([
        'INFO floresta_wire::p2p_wire::node::sync_ctx: Not enough utreexo '
            'peers (we have 0), opening a new connection',
      ]),
      isTrue,
    );
    expect(
      logsShowNoUtreexoPeers(['Not enough utreexo peers (we have 1)']),
      isTrue,
    );
    expect(
      logsShowNoUtreexoPeers(['Catching up with the network...']),
      isFalse,
    );
  });

  group('SYNC-06: never done while behind the network', () {
    test('Mandacaru #63: "done" at 17,904 while peers report ~947k', () {
      final s = _status(
        chain: _chain(headers: 17904, validated: 17904, ibd: false),
        peers: [_peer(initialHeight: 947000), _peer(initialHeight: 946990)],
        electrum: ElectrumCheck.ok,
      );
      final r = _assess(s);
      expect(r.stage, ReadinessStage.behindNetwork);
      expect(r.usable, isFalse);
      expect(r.peerTip, 947000);
      expect(StatusLabels.readiness(r, s).label, 'Behind the network');
      expect(StatusLabels.sync(r, s).label, 'Behind the network');
    });

    test('within the tolerance it is synced', () {
      final s = _status(
        chain: _chain(headers: 327840, validated: 327840, ibd: false),
        peers: [_peer(initialHeight: 327840 + peerTipTolerance)],
        electrum: ElectrumCheck.ok,
      );
      expect(_assess(s).stage, ReadinessStage.ready);
    });

    test('without peers there is nothing to compare: no false alarm', () {
      final s = _status(
        chain: _chain(headers: 10, validated: 10, ibd: false),
        electrum: ElectrumCheck.ok,
      );
      expect(_assess(s).stage, ReadinessStage.ready);
    });

    test('header progress is an estimate from peers, labelled as such', () {
      final s = _status(
        chain: _chain(headers: 192000, validated: 0, ibd: true),
        peers: [_peer(initialHeight: 327843)],
      );
      final caption = StatusLabels.headersCaption(_assess(s), s);
      expect(
        caption,
        '192,000 headers (about 58% of the network, estimated from peers)',
      );
      final noPeers = _status(
        chain: _chain(headers: 192000, validated: 0, ibd: true),
      );
      expect(
        StatusLabels.headersCaption(_assess(noPeers), noPeers),
        '192,000 headers',
      );
    });
  });

  test('SYNC-08: "Synced" appears only when readiness is ready', () {
    final snapshots = [
      _status(),
      _status(chain: _chain(headers: 0, validated: 0, ibd: true)),
      _status(
        chain: _chain(headers: 192000, validated: 0, ibd: true),
        peers: [_peer()],
      ),
      _status(
        chain: _chain(headers: 327843, validated: 296870, ibd: true),
        peers: [_peer()],
      ),
      _status(
        chain: _chain(headers: 17904, validated: 17904, ibd: false),
        peers: [_peer(initialHeight: 947000)],
      ),
      _status(
        chain: _chain(headers: 327843, validated: 327843, ibd: false),
        peers: [_peer(initialHeight: 327843)],
        electrum: ElectrumCheck.ok,
      ),
    ];
    for (final s in snapshots) {
      final r = _assess(s);
      final synced = StatusLabels.sync(r, s).label == 'Synced';
      expect(synced, r.stage == ReadinessStage.ready, reason: '${r.stage}');
    }
  });
}
