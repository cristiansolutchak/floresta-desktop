import 'package:equatable/equatable.dart';

/// Domain view of one `getpeerinfo` entry. Floresta's shape differs from
/// Bitcoin Core's (`crates/floresta-rpc/src/rpc_types.rs` `PeerInfo`).
class Peer extends Equatable {
  const Peer({
    required this.id,
    required this.address,
    required this.userAgent,
    required this.inbound,
    required this.kind,
    required this.state,
    required this.transport,
    required this.initialHeight,
    required this.services,
  });

  final int id;
  final String address;
  final String userAgent;
  final bool inbound;

  /// "Regular", "Feeler" or "Extra" upstream.
  final String kind;

  /// "Ready", "Connecting" or "Banned" upstream.
  final String state;
  final String transport;
  final int initialHeight;
  final List<String> services;

  bool get isReady => state.toLowerCase() == 'ready';

  /// NODE_UTREEXO is bit 12 (`floresta-common` `service_flags::UTREEXO =
  /// 1 << 12`). rust-bitcoin has no name for it, so it arrives inside the
  /// hex part of the flags (e.g. `0x1000`).
  bool get supportsUtreexo => services.any((s) {
    if (s.toUpperCase().contains('UTREEXO')) return true;
    if (!s.startsWith('0x')) return false;
    final bits = BigInt.tryParse(s.substring(2), radix: 16);
    return bits != null && (bits >> 12) & BigInt.one == BigInt.one;
  });

  @override
  List<Object?> get props => [id, address, state];
}

/// Connected peers by direction and transport (`getpeerinfo`
/// `transport_protocol` is "V1" or "V2" upstream).
class PeerCounts {
  const PeerCounts(this.inbound, this.outbound, this.v1, this.v2);

  factory PeerCounts.of(List<Peer> ready) => PeerCounts(
    ready.where((p) => p.inbound).length,
    ready.where((p) => !p.inbound).length,
    ready.where((p) => p.transport.toUpperCase() == 'V1').length,
    ready.where((p) => p.transport.toUpperCase() == 'V2').length,
  );

  final int inbound;
  final int outbound;
  final int v1;
  final int v2;
  int get total => inbound + outbound;
}
