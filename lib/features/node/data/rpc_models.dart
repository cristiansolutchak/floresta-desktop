import '../../settings/domain/bitcoin_network.dart';
import '../domain/blockchain_info.dart';
import '../domain/peer.dart';

/// JSON → domain mapping for florestad RPC responses.
///
/// Field names come from `corepc_types::v30::GetBlockchainInfo` and
/// Floresta's `PeerInfo`. Casts throw `TypeError` on shape changes, which
/// `guardRpc` turns into `RpcMalformedResponseFailure`.
abstract final class RpcModels {
  static BlockchainInfo blockchainInfo(Object? json) {
    final m = json as Map<String, Object?>;
    final chain = m['chain'] as String;
    return BlockchainInfo(
      chain: chain,
      network: BitcoinNetwork.fromChainName(chain),
      validatedHeight: (m['blocks'] as num).toInt(),
      headerHeight: (m['headers'] as num).toInt(),
      bestBlockHash: m['bestblockhash'] as String,
      verificationProgress: (m['verificationprogress'] as num).toDouble().clamp(
        0.0,
        1.0,
      ),
      initialBlockDownload: m['initialblockdownload'] as bool,
      tipTime: DateTime.fromMillisecondsSinceEpoch(
        (m['time'] as num).toInt() * 1000,
        isUtc: true,
      ),
      sizeOnDisk: (m['size_on_disk'] as num?)?.toInt() ?? 0,
      warnings: _warnings(m['warnings']),
    );
  }

  /// Core changed `warnings` from a string to a list in v28; accept both.
  static List<String> _warnings(Object? raw) => switch (raw) {
    final List<Object?> list => [
      for (final w in list)
        if (w != null && '$w'.isNotEmpty) '$w',
    ],
    final String s when s.isNotEmpty => [s],
    _ => const [],
  };

  static List<Peer> peers(Object? json) {
    final list = json as List<Object?>;
    return [for (final p in list) peer(p)];
  }

  static Peer peer(Object? json) {
    final m = json as Map<String, Object?>;
    return Peer(
      id: (m['id'] as num).toInt(),
      address: m['address'] as String,
      userAgent: (m['user_agent'] as String?) ?? '',
      inbound: (m['inbound'] as bool?) ?? false,
      kind: (m['kind'] as String?) ?? 'Unknown',
      state: (m['state'] as String?) ?? 'Unknown',
      transport: (m['transport_protocol'] as String?) ?? 'Unknown',
      initialHeight: (m['initial_height'] as num?)?.toInt() ?? 0,
      services: [
        for (final s in (m['servicesnames'] as List<Object?>?) ?? const [])
          '$s',
      ],
    );
  }
}
