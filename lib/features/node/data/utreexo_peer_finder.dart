import 'dart:async';
import 'dart:io';

import '../../settings/domain/bitcoin_network.dart';
import '../domain/node_rpc_repository.dart';
import '../domain/utreexo_peer.dart';
import 'p2p_version_probe.dart';

/// Resolves a host name to IP addresses. Injected so tests need no DNS.
typedef HostResolver = Future<List<String>> Function(String host);

Future<List<String>> resolveHost(String host) async {
  try {
    final found = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 5));
    return [for (final a in found) a.address];
  } on Object {
    return const [];
  }
}

/// Probes one address. Injected so tests need no network.
typedef ProbeAddress =
    Future<PeerProbe> Function(String host, int port, BitcoinNetwork network);

/// One candidate and what was done with it.
class UtreexoPeerAttempt {
  const UtreexoPeerAttempt(this.address, this.probe, this.action);
  final String address;
  final PeerProbe probe;

  /// `add` (verified Utreexo over v1), `onetry-v2` (no v1 answer: let the
  /// node try its encrypted transport once), or null (skipped).
  final String? action;
}

/// SYNC-05: finds Utreexo peers for florestad v0.9.1, whose built-in seeds
/// no longer answer. Candidates come from the seeds upstream maintains
/// ([utreexoSeeds]) and [curatedUtreexoPeers]; each is checked with a P2P
/// handshake first, so nothing unverified is added permanently:
///
/// - Utreexo bit, right network, height past the snapshot: `addnode add`
///   over v1 (v0.9.1 does not fall back to v1 on its own, and utreexod
///   nodes may not speak v2);
/// - no v1 answer (likely a v2-only node): `addnode onetry` with v2, so
///   florestad itself checks it; it is kept only if it then shows up as a
///   Utreexo peer, which florestad remembers in its own `anchors.json`;
/// - anything else (wrong network, no Utreexo bit, too far behind): skipped.
class UtreexoPeerFinder {
  UtreexoPeerFinder({
    required this.rpc,
    HostResolver? resolve,
    ProbeAddress? probe,
    this.maxPerRound = 8,
  }) : _resolve = resolve ?? resolveHost,
       _probe = probe ?? P2pVersionProbe().probe;

  final NodeRpcRepository rpc;
  final HostResolver _resolve;
  final ProbeAddress _probe;
  final int maxPerRound;

  /// Seed results first (fresher), then the curated list, deduplicated.
  Future<List<String>> candidates(BitcoinNetwork network) async {
    final out = <String>{};
    for (final seed in utreexoSeeds[network] ?? const <String>[]) {
      for (final ip in await _resolve('$utreexoSeedFilter.$seed')) {
        out.add(
          ip.contains(':')
              ? '[$ip]:${network.p2pPort}'
              : '$ip:${network.p2pPort}',
        );
      }
    }
    for (final c in curatedUtreexoPeers[network] ?? const []) {
      out.add(c.address);
    }
    return out.take(maxPerRound).toList();
  }

  Future<List<UtreexoPeerAttempt>> run(
    BitcoinNetwork network, {
    int? networkTip,
    Set<String> alreadyConnected = const {},
  }) async {
    final list = [
      for (final c in await candidates(network))
        if (!alreadyConnected.contains(c)) c,
    ];
    final probes = await Future.wait([
      for (final c in list) _probe(_host(c), _port(c), network),
    ]);
    final attempts = <UtreexoPeerAttempt>[];
    for (var i = 0; i < list.length; i++) {
      final probe = probes[i];
      final verdict = judgeUtreexoCandidate(
        probe,
        network: network,
        networkTip: networkTip,
      );
      String? action;
      if (verdict == UtreexoCandidateVerdict.usable) {
        final r = await rpc.addNode(list[i], command: AddNodeCommand.add);
        action = r.isRight() ? 'add' : null;
      } else if (verdict == UtreexoCandidateVerdict.unreachable &&
          probe.error == noVersionReply) {
        final r = await rpc.addNode(
          list[i],
          command: AddNodeCommand.onetry,
          v2transport: true,
        );
        action = r.isRight() ? 'onetry-v2' : null;
      }
      attempts.add(UtreexoPeerAttempt(list[i], probe, action));
    }
    return attempts;
  }

  static String _host(String address) {
    final i = address.lastIndexOf(':');
    final host = address.substring(0, i);
    return host.startsWith('[') ? host.substring(1, host.length - 1) : host;
  }

  static int _port(String address) =>
      int.parse(address.substring(address.lastIndexOf(':') + 1));
}
