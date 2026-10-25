import 'dart:convert';
import 'dart:io';

import 'package:floresta_gui/core/electrum/electrum_client.dart';
import 'package:floresta_gui/core/electrum/electrum_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-process TCP server speaking newline-delimited JSON, scripted per test.
class FakeElectrumServer {
  late final ServerSocket _server;
  final _clients = <Socket>[];
  final received = <Object?>[];

  /// Returns the reply line(s) for one decoded request line, or null for no
  /// reply. Default: echo `result: method`.
  Object? Function(Object? request)? onRequest;

  int get port => _server.port;

  /// The client's `connect()` can complete before this side has accepted
  /// the socket; tests that act on server-side sockets wait for it first.
  Future<void> waitForClients(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_clients.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('server saw ${_clients.length} of $count clients');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _clients.add(socket);
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final req = jsonDecode(line);
            received.add(req);
            final reply = (onRequest ?? _echo)(req);
            if (reply != null) socket.write('${jsonEncode(reply)}\n');
          });
    });
  }

  static Object? _echo(Object? req) => req is List
      ? [for (final r in req) _echo(r)]
      : {'jsonrpc': '2.0', 'id': (req as Map)['id'], 'result': req['method']};

  void push(Object notification) {
    for (final c in _clients) {
      c.write('${jsonEncode(notification)}\n');
    }
  }

  void writeRaw(String text) {
    for (final c in _clients) {
      c.write(text);
    }
  }

  Future<void> dropClients() async {
    for (final c in _clients) {
      c.destroy();
    }
    _clients.clear();
  }

  Future<void> stop() async {
    await dropClients();
    await _server.close();
  }
}

void main() {
  late FakeElectrumServer server;
  late ElectrumTransport transport;

  setUp(() async {
    server = FakeElectrumServer();
    await server.start();
    transport = ElectrumTransport(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(milliseconds: 500),
    );
    await transport.connect();
  });

  tearDown(() async {
    await transport.dispose();
    await server.stop();
  });

  test('correlates a request with its response', () async {
    expect(await transport.request('server.ping'), 'server.ping');
  });

  test('sends batches as one JSON array and keeps result order', () async {
    server.onRequest = (req) => [
      // Reply out of order: correlation must use ids.
      for (final r in (req as List).reversed)
        {'id': (r as Map)['id'], 'result': r['params'][0]},
    ];
    final results = await transport.batch([
      ('blockchain.scripthash.get_history', ['a']),
      ('blockchain.scripthash.get_history', ['b']),
      ('blockchain.scripthash.get_history', ['c']),
    ]);
    expect(results, ['a', 'b', 'c']);
    expect(server.received.single, isA<List<Object?>>());
  });

  test('delivers notifications interleaved with responses', () async {
    final notes = <ElectrumNotification>[];
    final sub = transport.notifications.listen(notes.add);
    server.onRequest = (req) {
      server.push({
        'jsonrpc': '2.0',
        'method': 'blockchain.scripthash.subscribe',
        'params': ['abcd', 'status1'],
      });
      return {'id': (req as Map)['id'], 'result': 'ok'};
    };
    expect(await transport.request('server.ping'), 'ok');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(notes.single.method, 'blockchain.scripthash.subscribe');
    expect(notes.single.params, ['abcd', 'status1']);
    await sub.cancel();
  });

  test('maps server errors', () async {
    server.onRequest = (req) => {
      'id': (req as Map)['id'],
      'error': {'code': -32000, 'message': 'Internal JSON-RPC error.'},
    };
    await expectLater(
      transport.request('blockchain.scripthash.nope'),
      throwsA(
        isA<ElectrumServerException>().having((e) => e.code, 'code', -32000),
      ),
    );
  });

  test('times out without a reply', () async {
    server.onRequest = (_) => null;
    await expectLater(
      transport.request('server.ping'),
      throwsA(isA<ElectrumTimeoutException>()),
    );
  });

  test('fails pending requests and reports the drop on EOF', () async {
    server.onRequest = (_) => null;
    final dropped = transport.disconnects.first;
    final pending = transport.request('blockchain.scripthash.get_history', [
      'x',
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.dropClients();
    await expectLater(pending, throwsA(isA<ElectrumConnectionException>()));
    await dropped;
    expect(transport.isConnected, isFalse);
    await expectLater(
      transport.request('server.ping'),
      throwsA(isA<ElectrumConnectionException>()),
    );
  });

  test('drops the connection on a malformed line', () async {
    server.onRequest = (_) {
      server.writeRaw('{not json\n');
      return null;
    };
    await expectLater(
      transport.request('server.ping'),
      throwsA(isA<ElectrumConnectionException>()),
    );
  });

  test('reconnects after a drop', () async {
    // Subscribe before dropping: `disconnects` is a broadcast stream and
    // would not replay an event that fired before listening.
    await server.waitForClients(1);
    final dropped = transport.disconnects.first;
    await server.dropClients();
    await dropped;
    await transport.connect();
    expect(await transport.request('server.ping'), 'server.ping');
  });

  test('refused connections fail fast', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final t = ElectrumTransport(host: '127.0.0.1', port: port);
    await expectLater(t.connect(), throwsA(isA<ElectrumConnectionException>()));
  });

  group('TcpElectrumClient', () {
    test('parses handshake, history, merkle and notifications', () async {
      server.onRequest = (req) {
        Map<String, Object?> reply(Map r) => {
          'id': r['id'],
          'result': switch (r['method']) {
            'server.version' => ['Floresta 0.5.1', '1.4'],
            'server.features' => {'genesis_hash': 'g' * 64},
            'blockchain.scripthash.get_history' => [
              {'tx_hash': 't1', 'height': 5},
              {'tx_hash': 't2', 'height': 0},
            ],
            'blockchain.transaction.get_merkle' => {
              'block_height': 5,
              'pos': 1,
              'merkle': ['aa'],
            },
            _ => null,
          },
        };
        return req is List
            ? [for (final r in req) reply(r as Map)]
            : reply(req as Map);
      };
      final client = TcpElectrumClient(transport);
      final events = <ElectrumEvent>[];
      final sub = client.events.listen(events.add);

      final f = await client.handshake();
      expect(f.serverVersion, 'Floresta 0.5.1');
      expect(f.genesisHash, 'g' * 64);
      expect(await client.history('sh'), const [
        HistoryEntry('t1', 5),
        HistoryEntry('t2', 0),
      ]);
      expect(
        await client.merkle('t1', 5),
        const MerkleProof(blockHeight: 5, position: 1, siblings: ['aa']),
      );

      server.push({
        'method': 'blockchain.headers.subscribe',
        'params': [
          {'height': 7, 'hex': '00' * 80},
        ],
      });
      server.push({
        'method': 'blockchain.scripthash.subscribe',
        'params': ['sh', null],
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.whereType<NewHeader>().single.tip.height, 7);
      expect(events.whereType<ScriptStatusChanged>().single.status, isNull);
      await sub.cancel();
    });
  });
}
