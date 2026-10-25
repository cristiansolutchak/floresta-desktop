import '../../settings/domain/bitcoin_network.dart';
import '../domain/blockchain_info.dart';
import '../domain/peer.dart';

/// JSON → domain mapping for florestad RPC responses.
///
/// Field names come from Floresta's `PeerInfo` and two `getblockchaininfo`
/// shapes (see [blockchainInfo]). Casts throw `TypeError` on shape changes,
/// which `guardRpc` turns into `RpcMalformedResponseFailure`.
abstract final class RpcModels {
  /// Accepts both upstream shapes of `getblockchaininfo`:
  /// * v0.9.x releases: Floresta's own `GetBlockchainInfoRes`
  ///   (`best_block`, `height`, `validated`, `ibd`, `progress`, …;
  ///   `crates/floresta-rpc/src/rpc_types.rs` at tag v0.9.1).
  /// * `master` after v0.9.1: `corepc_types::v30::GetBlockchainInfo`
  ///   (`blocks`, `headers`, `bestblockhash`, …).
  static BlockchainInfo blockchainInfo(Object? json) {
    final m = json as Map<String, Object?>;
    if (m.containsKey('best_block')) return _blockchainInfoV09(m);
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
      sizeOnDisk: (m['size_on_disk'] as num?)?.toInt(),
      warnings: _warnings(m['warnings']),
    );
  }

  static BlockchainInfo _blockchainInfoV09(Map<String, Object?> m) {
    final chain = m['chain'] as String;
    return BlockchainInfo(
      chain: chain,
      network: BitcoinNetwork.fromChainName(chain),
      validatedHeight: (m['validated'] as num).toInt(),
      headerHeight: (m['height'] as num).toInt(),
      bestBlockHash: m['best_block'] as String,
      verificationProgress: (m['progress'] as num).toDouble().clamp(0.0, 1.0),
      initialBlockDownload: m['ibd'] as bool,
      tipTime: DateTime.fromMillisecondsSinceEpoch(
        (m['latest_block_time'] as num).toInt() * 1000,
        isUtc: true,
      ),
      // v0.9.x reports neither disk usage nor warnings.
      sizeOnDisk: null,
      warnings: const [],
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

  /// Two upstream shapes of `getpeerinfo.services`:
  /// * v0.9.1: rust-bitcoin's `ServiceFlags` Display string, e.g.
  ///   `"ServiceFlags(NETWORK|WITNESS|P2P_V2|0x1000)"`
  ///   (`floresta-wire/src/p2p_wire/node_interface.rs`
  ///   `serialize_service_flags`; bitcoin 0.32.8 `p2p/mod.rs`): named
  ///   flags, then all unnamed bits as one hex value.
  /// * master after v0.9.1 (#1210): a Core-style hex bitmask
  ///   (`"0000000000001c49"`) plus a `servicesnames` list. The bitmask is
  ///   kept as a `0x…` token so bits without a name (NODE_UTREEXO = bit 12)
  ///   are never lost.
  static List<String> serviceFlags(Object? services, Object? names) {
    if (services is String && _hexMask.hasMatch(services)) {
      final bits = BigInt.parse(services, radix: 16);
      return [
        for (final s in (names as List<Object?>?) ?? const []) '$s',
        '0x${bits.toRadixString(16)}',
      ];
    }
    if (services is String) {
      final open = services.indexOf('(');
      final close = services.lastIndexOf(')');
      if (open >= 0 && close > open) {
        final inner = services.substring(open + 1, close).trim();
        if (inner.isEmpty || inner == 'NONE') return const [];
        return inner.split('|').map((s) => s.trim()).toList();
      }
    }
    return [for (final s in (names as List<Object?>?) ?? const []) '$s'];
  }

  static final _hexMask = RegExp(r'^[0-9a-fA-F]{1,16}$');

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
      services: serviceFlags(m['services'], m['servicesnames']),
    );
  }
}
