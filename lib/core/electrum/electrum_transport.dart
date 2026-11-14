import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Data-layer exceptions; mapped to `Failure`s by callers.
sealed class ElectrumException implements Exception {
  const ElectrumException(this.method);
  final String method;
}

final class ElectrumConnectionException extends ElectrumException {
  const ElectrumConnectionException(super.method, this.detail);
  final String detail;
  @override
  String toString() => 'ElectrumConnectionException($method): $detail';
}

final class ElectrumTimeoutException extends ElectrumException {
  const ElectrumTimeoutException(super.method, this.timeout);
  final Duration timeout;
  @override
  String toString() => 'ElectrumTimeoutException($method, $timeout)';
}

final class ElectrumServerException extends ElectrumException {
  const ElectrumServerException(super.method, this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'ElectrumServerException($method, $code): $message';
}

final class ElectrumProtocolException extends ElectrumException {
  const ElectrumProtocolException(super.method, this.detail);
  final String detail;
  @override
  String toString() => 'ElectrumProtocolException($method): $detail';
}

/// A server-initiated message (no `id`), e.g. a subscription update.
class ElectrumNotification {
  const ElectrumNotification(this.method, this.params);
  final String method;
  final List<Object?> params;
}

typedef SocketConnector =
    Future<Socket> Function(String host, int port, Duration timeout);

Future<Socket> _defaultConnect(String host, int port, Duration timeout) =>
    Socket.connect(host, port, timeout: timeout);

/// Electrum protocol transport: newline-delimited JSON-RPC 2.0 over TCP.
///
/// Verified against florestad v0.9.1: plain TCP, batching supported,
/// notifications interleaved with responses, EOF on server shutdown. Every
/// pending request
/// fails as soon as the connection drops, so callers never hang.
class ElectrumTransport {
  ElectrumTransport({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 20),
    SocketConnector? connector,
  }) : _connect = connector ?? _defaultConnect;

  final String host;
  final int port;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final SocketConnector _connect;

  Socket? _socket;
  StreamSubscription<String>? _lines;
  int _nextId = 1;
  final _pending = <int, (String, Completer<Object?>)>{};
  final _notifications = StreamController<ElectrumNotification>.broadcast();
  final _closed = StreamController<Object?>.broadcast();

  String get endpoint => '$host:$port';
  bool get isConnected => _socket != null;

  /// Server-initiated messages.
  Stream<ElectrumNotification> get notifications => _notifications.stream;

  /// Emits once per lost connection (the error, or null on clean EOF).
  Stream<Object?> get disconnects => _closed.stream;

  Future<void> connect() async {
    if (_socket != null) return;
    final Socket socket;
    try {
      socket = await _connect(host, port, connectTimeout);
    } on SocketException catch (e) {
      throw ElectrumConnectionException('connect', e.message);
    } on TimeoutException {
      throw ElectrumTimeoutException('connect', connectTimeout);
    }
    _socket = socket;
    _lines = socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onLine,
          // Bound to this socket: a late event from an old connection must
          // never tear down a newer one after a reconnect.
          onError: (Object e) => _drop(e, socket),
          onDone: () => _drop(null, socket),
          cancelOnError: true,
        );
  }

  Future<Object?> request(
    String method, [
    List<Object?> params = const [],
    Duration? timeout,
  ]) async {
    final results = await batch([(method, params)], timeout);
    return results.single;
  }

  /// Sends several requests in one JSON array and returns their results in
  /// order. Any error response throws for the whole batch.
  Future<List<Object?>> batch(
    List<(String, List<Object?>)> calls, [
    Duration? timeout,
  ]) async {
    if (calls.isEmpty) return const [];
    final socket = _socket;
    final label = calls.first.$1;
    if (socket == null) {
      throw ElectrumConnectionException(label, 'not connected');
    }
    final futures = <Future<Object?>>[];
    final payload = <Map<String, Object?>>[];
    for (final (method, params) in calls) {
      final id = _nextId++;
      final completer = Completer<Object?>();
      _pending[id] = (method, completer);
      futures.add(completer.future);
      payload.add({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    }
    socket.write(
      '${jsonEncode(payload.length == 1 ? payload.single : payload)}\n',
    );
    final effective = timeout ?? requestTimeout;
    try {
      return await Future.wait(futures).timeout(effective);
    } on TimeoutException {
      for (final p in payload) {
        _pending.remove(p['id']);
      }
      throw ElectrumTimeoutException(label, effective);
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _drop(const ElectrumProtocolException('stream', 'invalid JSON line'));
      return;
    }
    final messages = decoded is List ? decoded : [decoded];
    for (final m in messages) {
      if (m is! Map<String, Object?>) continue;
      final id = m['id'];
      if (id == null) {
        final method = m['method'];
        final params = m['params'];
        if (method is String) {
          _notifications.add(
            ElectrumNotification(method, params is List ? params : const []),
          );
        }
        continue;
      }
      final entry = _pending.remove(id);
      if (entry == null) continue; // late reply to a timed-out request
      final (method, completer) = entry;
      final error = m['error'];
      if (error != null) {
        final e = error is Map ? error : const {};
        completer.completeError(
          ElectrumServerException(
            method,
            (e['code'] as num?)?.toInt() ?? -32603,
            e['message']?.toString() ?? '$error',
          ),
        );
      } else {
        completer.complete(m['result']);
      }
    }
  }

  void _drop(Object? error, [Socket? origin]) {
    final socket = _socket;
    if (socket == null) return;
    if (origin != null && !identical(origin, socket)) return;
    _socket = null;
    unawaited(_lines?.cancel());
    socket.destroy();
    final pending = Map.of(_pending);
    _pending.clear();
    for (final MapEntry(value: (method, completer)) in pending.entries) {
      completer.completeError(
        ElectrumConnectionException(
          method,
          'connection lost: ${error ?? 'EOF'}',
        ),
      );
    }
    if (!_closed.isClosed) _closed.add(error);
  }

  Future<void> close() async {
    _drop(null);
  }

  Future<void> dispose() async {
    await close();
    await _notifications.close();
    await _closed.close();
  }
}
