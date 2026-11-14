import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart';

import '../../settings/domain/bitcoin_network.dart';
import '../domain/utreexo_peer.dart';

/// Asks a Bitcoin node who it is, with the plain (v1) P2P
/// handshake, and stops there. It sends one `version` message and reads the
/// peer's `version`; it never sends `verack`, requests no data and keeps no
/// connection. That is enough to learn the network (from the message magic),
/// the advertised services (Utreexo is bit 12) and the peer's height.
class P2pVersionProbe {
  P2pVersionProbe({this.timeout = const Duration(seconds: 6)});

  final Duration timeout;

  static const _protocolVersion = 70016;
  static const _userAgent = '/floresta-desktop-probe:0.1/';

  /// Message start bytes per network (Bitcoin Core `chainparams.cpp`).
  static Uint8List magic(BitcoinNetwork n) => Uint8List.fromList(switch (n) {
    BitcoinNetwork.bitcoin => [0xf9, 0xbe, 0xb4, 0xd9],
    BitcoinNetwork.signet => [0x0a, 0x03, 0xcf, 0x40],
    BitcoinNetwork.testnet4 => [0x1c, 0x16, 0x3f, 0x28],
    BitcoinNetwork.regtest => [0xfa, 0xbf, 0xb5, 0xda],
  });

  Future<PeerProbe> probe(String host, int port, BitcoinNetwork network) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.add(versionMessage(network));
      await socket.flush();
      final reply = await _readVersion(socket, network).timeout(timeout);
      return reply;
    } on TimeoutException {
      return const PeerProbe.failed('no answer');
    } on SocketException catch (e) {
      return PeerProbe.failed(e.osError?.message ?? e.message);
    } on FormatException catch (e) {
      return PeerProbe.failed(e.message);
    } on Object {
      // Anything unexpected from a remote peer is just "no usable answer".
      return const PeerProbe.failed('unexpected reply');
    } finally {
      socket?.destroy();
    }
  }

  /// A complete `version` message with [network]'s magic.
  static Uint8List versionMessage(BitcoinNetwork network, {int? nonce}) {
    final p = BytesBuilder();
    void u32(int v) => p.add(
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
    );
    void u64(int v) => p.add(
      (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List(),
    );
    void netAddr() {
      u64(0); // services
      p.add(Uint8List(16)); // IPv6 :: (unspecified)
      p.add([0, 0]); // port
    }

    u32(_protocolVersion);
    u64(0); // we serve nothing
    u64(DateTime.now().millisecondsSinceEpoch ~/ 1000);
    netAddr();
    netAddr();
    u64(nonce ?? Random.secure().nextInt(1 << 32));
    p.addByte(_userAgent.length);
    p.add(_userAgent.codeUnits);
    u32(0); // start height
    p.addByte(0); // relay: false
    return frame(network, 'version', p.toBytes());
  }

  /// Wraps [payload] in a v1 message header.
  static Uint8List frame(
    BitcoinNetwork network,
    String command,
    List<int> payload,
  ) {
    final header = BytesBuilder()
      ..add(magic(network))
      ..add([...command.codeUnits, ...List.filled(12 - command.length, 0)])
      ..add(
        (ByteData(
          4,
        )..setUint32(0, payload.length, Endian.little)).buffer.asUint8List(),
      )
      ..add(QuickCrypto.sha256DoubleHash(payload).sublist(0, 4));
    return (BytesBuilder()
          ..add(header.toBytes())
          ..add(payload))
        .toBytes();
  }

  Future<PeerProbe> _readVersion(Socket socket, BitcoinNetwork network) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      buf.add(chunk);
      final bytes = buf.toBytes();
      final parsed = parseVersionReply(bytes, network);
      if (parsed != null) return parsed;
      if (bytes.length > 64 * 1024) break;
    }
    return const PeerProbe.failed(noVersionReply);
  }

  /// Parses the first complete message in [bytes]. Returns null when more
  /// bytes are needed.
  static PeerProbe? parseVersionReply(Uint8List bytes, BitcoinNetwork network) {
    if (bytes.length < 24) return null;
    final want = magic(network);
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != want[i]) {
        return PeerProbe.failed(
          'answered with the magic of another network or protocol',
        );
      }
    }
    final data = ByteData.sublistView(bytes);
    final command = String.fromCharCodes(
      bytes.sublist(4, 16).takeWhile((b) => b != 0),
    );
    final length = data.getUint32(16, Endian.little);
    if (bytes.length < 24 + length) return null;
    if (command != 'version') {
      return PeerProbe.failed('first message was "$command", not version');
    }
    // version(4) services(8) time(8) addr_recv(26) addr_from(26) nonce(8)
    // user-agent length(1) ... start height(4)
    const fixed = 4 + 8 + 8 + 26 + 26 + 8;
    if (length < fixed + 1 + 4) {
      return const PeerProbe.failed('malformed version message');
    }
    final p = ByteData.sublistView(bytes, 24, 24 + length);
    var o = 0;
    final version = p.getInt32(o, Endian.little);
    o += 4;
    final services = p.getUint64(o, Endian.little);
    o = fixed;
    final uaLen = p.getUint8(o); // user agents are < 253 bytes
    o += 1;
    if (uaLen >= 253 || o + uaLen + 4 > length) {
      return const PeerProbe.failed('malformed version message');
    }
    final ua = String.fromCharCodes(Uint8List.sublistView(p, o, o + uaLen));
    o += uaLen;
    final height = p.getInt32(o, Endian.little);
    return PeerProbe(
      protocolVersion: version,
      services: services,
      userAgent: ua,
      height: height,
    );
  }
}
