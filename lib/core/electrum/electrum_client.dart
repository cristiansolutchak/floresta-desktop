import 'package:equatable/equatable.dart';

import 'electrum_transport.dart';

class ServerFeatures extends Equatable {
  const ServerFeatures({
    required this.serverVersion,
    required this.protocolVersion,
    required this.genesisHash,
  });

  final String serverVersion;
  final String protocolVersion;
  final String genesisHash;

  @override
  List<Object?> get props => [serverVersion, protocolVersion, genesisHash];
}

class HeaderTip extends Equatable {
  const HeaderTip(this.height, this.headerHex);
  final int height;
  final String headerHex;
  @override
  List<Object?> get props => [height, headerHex];
}

/// One `get_history` entry. `height <= 0` means unconfirmed.
class HistoryEntry extends Equatable {
  const HistoryEntry(this.txid, this.height);
  final String txid;
  final int height;
  @override
  List<Object?> get props => [txid, height];
}

class MerkleProof extends Equatable {
  const MerkleProof({
    required this.blockHeight,
    required this.position,
    required this.siblings,
  });
  final int blockHeight;
  final int position;

  /// Sibling hashes in display (reversed) hex, leaf level first.
  final List<String> siblings;
  @override
  List<Object?> get props => [blockHeight, position, siblings];
}

sealed class ElectrumEvent {
  const ElectrumEvent();
}

final class ScriptStatusChanged extends ElectrumEvent {
  const ScriptStatusChanged(this.scripthash, this.status);
  final String scripthash;
  final String? status;
}

final class NewHeader extends ElectrumEvent {
  const NewHeader(this.tip);
  final HeaderTip tip;
}

/// Typed Electrum protocol methods used by wallet sync.
///
/// All methods exist in florestad v0.9.1
/// (`crates/floresta-electrum/src/electrum_protocol.rs`) and were exercised
/// against a real node on regtest (see ADR-0008 evidence).
abstract interface class ElectrumClient {
  String get endpoint;
  Stream<ElectrumEvent> get events;
  Stream<Object?> get disconnects;
  bool get isConnected;

  Future<void> connect();
  Future<ServerFeatures> handshake();
  Future<HeaderTip> subscribeHeaders();
  Future<String> blockHeader(int height);

  /// Batched `blockchain.scripthash.subscribe`; returns the status per hash.
  Future<Map<String, String?>> subscribeScripthashes(List<String> hashes);
  Future<List<HistoryEntry>> history(String scripthash);

  /// Batched `blockchain.transaction.get`; returns raw hex per txid.
  Future<Map<String, String>> transactions(List<String> txids);
  Future<MerkleProof> merkle(String txid, int height);
  Future<void> close();
}

class TcpElectrumClient implements ElectrumClient {
  TcpElectrumClient(this._transport);

  final ElectrumTransport _transport;
  static const _batchSize = 50;

  @override
  String get endpoint => _transport.endpoint;
  @override
  bool get isConnected => _transport.isConnected;
  @override
  Stream<Object?> get disconnects => _transport.disconnects;

  @override
  Stream<ElectrumEvent> get events =>
      _transport.notifications.map(_toEvent).where((e) => e != null).cast();

  ElectrumEvent? _toEvent(ElectrumNotification n) {
    switch (n.method) {
      case 'blockchain.scripthash.subscribe' when n.params.length >= 2:
        final hash = n.params[0];
        final status = n.params[1];
        if (hash is String && (status == null || status is String)) {
          return ScriptStatusChanged(hash, status as String?);
        }
      case 'blockchain.headers.subscribe' when n.params.isNotEmpty:
        final tip = _parseTip(n.params.first);
        if (tip != null) return NewHeader(tip);
    }
    return null;
  }

  @override
  Future<void> connect() => _transport.connect();

  @override
  Future<ServerFeatures> handshake() async {
    final results = await _transport.batch([
      ('server.version', ['floresta-gui', '1.4']),
      ('server.features', const []),
    ]);
    final version = results[0];
    final features = results[1];
    if (version is! List || version.length < 2 || features is! Map) {
      throw const ElectrumProtocolException('handshake', 'bad shape');
    }
    final genesis = features['genesis_hash'];
    if (genesis is! String) {
      throw const ElectrumProtocolException('server.features', 'no genesis');
    }
    return ServerFeatures(
      serverVersion: '${version[0]}',
      protocolVersion: '${version[1]}',
      genesisHash: genesis,
    );
  }

  @override
  Future<HeaderTip> subscribeHeaders() async {
    final tip = _parseTip(
      await _transport.request('blockchain.headers.subscribe'),
    );
    if (tip == null) {
      throw const ElectrumProtocolException('headers.subscribe', 'bad shape');
    }
    return tip;
  }

  HeaderTip? _parseTip(Object? raw) {
    if (raw is Map && raw['height'] is num && raw['hex'] is String) {
      return HeaderTip((raw['height'] as num).toInt(), raw['hex'] as String);
    }
    return null;
  }

  @override
  Future<String> blockHeader(int height) async {
    final hex = await _transport.request('blockchain.block.header', [height]);
    if (hex is! String || hex.length != 160) {
      throw const ElectrumProtocolException('block.header', 'not 80 bytes');
    }
    return hex;
  }

  @override
  Future<Map<String, String?>> subscribeScripthashes(
    List<String> hashes,
  ) async {
    final out = <String, String?>{};
    for (final chunk in _chunks(hashes)) {
      final results = await _transport.batch([
        for (final h in chunk) ('blockchain.scripthash.subscribe', [h]),
      ]);
      for (var i = 0; i < chunk.length; i++) {
        final s = results[i];
        if (s != null && s is! String) {
          throw const ElectrumProtocolException(
            'scripthash.subscribe',
            'status',
          );
        }
        out[chunk[i]] = s as String?;
      }
    }
    return out;
  }

  @override
  Future<List<HistoryEntry>> history(String scripthash) async {
    final raw = await _transport.request('blockchain.scripthash.get_history', [
      scripthash,
    ]);
    if (raw is! List) {
      throw const ElectrumProtocolException('get_history', 'not a list');
    }
    return [
      for (final e in raw)
        if (e is Map && e['tx_hash'] is String && e['height'] is num)
          HistoryEntry(e['tx_hash'] as String, (e['height'] as num).toInt())
        else
          throw const ElectrumProtocolException('get_history', 'bad entry'),
    ];
  }

  @override
  Future<Map<String, String>> transactions(List<String> txids) async {
    final out = <String, String>{};
    for (final chunk in _chunks(txids)) {
      final results = await _transport.batch([
        for (final t in chunk) ('blockchain.transaction.get', [t]),
      ]);
      for (var i = 0; i < chunk.length; i++) {
        final raw = results[i];
        if (raw is! String) {
          throw const ElectrumProtocolException('transaction.get', 'not hex');
        }
        out[chunk[i]] = raw;
      }
    }
    return out;
  }

  @override
  Future<MerkleProof> merkle(String txid, int height) async {
    final raw = await _transport.request('blockchain.transaction.get_merkle', [
      txid,
      height,
    ]);
    if (raw is! Map ||
        raw['block_height'] is! num ||
        raw['pos'] is! num ||
        raw['merkle'] is! List) {
      throw const ElectrumProtocolException('get_merkle', 'bad shape');
    }
    return MerkleProof(
      blockHeight: (raw['block_height'] as num).toInt(),
      position: (raw['pos'] as num).toInt(),
      siblings: [for (final s in raw['merkle'] as List) '$s'],
    );
  }

  Iterable<List<String>> _chunks(List<String> items) sync* {
    for (var i = 0; i < items.length; i += _batchSize) {
      yield items.sublist(
        i,
        i + _batchSize > items.length ? items.length : i + _batchSize,
      );
    }
  }

  @override
  Future<void> close() => _transport.close();
}
