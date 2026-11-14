import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:floresta_desktop/features/installation/data/signed_manifest.dart';

/// Release signing key created at test runtime (never stored or committed).
class TestReleaseKey {
  TestReleaseKey._(this._seed, this.id);

  factory TestReleaseKey.generate({String id = 'test-key'}) {
    final rnd = Random.secure();
    return TestReleaseKey._(
      List<int>.generate(32, (_) => rnd.nextInt(256)),
      id,
    );
  }

  final List<int> _seed;
  final String id;

  Ed25519Signer get _signer => Ed25519Signer.fromKeyBytes(_seed);

  TrustedReleaseKey get trusted => TrustedReleaseKey(
    id: id,
    publicKeyHex: BytesUtils.toHexString(publicKey),
  );

  /// Raw 32-byte public key (`compressed` carries a 1-byte prefix).
  List<int> get publicKey =>
      Ed25519PrivateKey.fromBytes(_seed).publicKey.compressed.sublist(1);

  List<int> sign(List<int> message) => _signer.sign(message);

  /// Signed envelope around [payload] (a JSON object).
  List<int> envelope(Map<String, Object?> payload, {String? keyId}) {
    final bytes = utf8.encode(jsonEncode(payload));
    return utf8.encode(
      jsonEncode({
        'keyId': keyId ?? id,
        'payload': base64.encode(bytes),
        'signature': base64.encode(sign(bytes)),
      }),
    );
  }
}

/// In-process HTTP server for installer tests, with fault injection.
class LocalArtifactServer {
  late final HttpServer _server;
  final files = <String, List<int>>{};
  final requests = <({String path, String? range})>[];

  /// Close the connection after this many body bytes, for the next N requests.
  int dropAfterBytes = -1;
  int dropTimes = 0;

  /// Respond with this status for the next N requests.
  int failStatus = 0;
  int failTimes = 0;

  bool honourRange = true;

  /// When set, fault injection applies only to this path.
  String? faultPath;

  /// Path → `Location` header answered with 302 Found.
  final redirects = <String, String>{};

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    requests.add((path: path, range: range));
    final res = req.response;
    if (redirects[path] case final location?) {
      res.statusCode = HttpStatus.found;
      res.headers.set(HttpHeaders.locationHeader, location);
      await res.close();
      return;
    }
    final faultsApply = faultPath == null || faultPath == path;
    if (faultsApply && failTimes > 0) {
      failTimes--;
      res.statusCode = failStatus;
      await res.close();
      return;
    }
    final body = files[path];
    if (body == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    var start = 0;
    if (honourRange && range != null && range.startsWith('bytes=')) {
      start = int.parse(range.substring(6).split('-').first);
      if (start >= body.length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${body.length - 1}/${body.length}',
      );
    }
    final slice = body.sublist(start);
    if (faultsApply && dropTimes > 0 && dropAfterBytes >= 0) {
      dropTimes--;
      // Announce the full length, send part of it, then cut the connection.
      res.headers.contentLength = slice.length;
      final socket = await res.detachSocket();
      socket.add(slice.sublist(0, min(dropAfterBytes, slice.length)));
      await socket.flush();
      socket.destroy();
      return;
    }
    res.headers.contentLength = slice.length;
    res.add(slice);
    await res.close();
  }

  Future<void> stop() => _server.close(force: true);
}
