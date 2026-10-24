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
  bool get supportsUtreexo =>
      services.any((s) => s.toUpperCase().contains('UTREEXO'));

  @override
  List<Object?> get props => [id, address, state];
}
