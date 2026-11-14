import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:floresta_desktop/core/errors/failure.dart';
import 'package:floresta_desktop/core/rpc/json_rpc_client.dart';
import 'package:floresta_desktop/core/rpc/rpc_failure_mapper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _endpoint = Uri.parse('http://127.0.0.1:38332/');

JsonRpcClient _client(
  Future<http.Response> Function(http.Request) handler, {
  Duration timeout = const Duration(seconds: 1),
}) => JsonRpcClient(
  endpoint: _endpoint,
  httpClient: MockClient(handler),
  defaultTimeout: timeout,
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('JsonRpcClient', () {
    test('sends a JSON-RPC 2.0 POST and returns result', () async {
      late Map<String, Object?> sent;
      final client = _client((req) async {
        sent = jsonDecode(req.body) as Map<String, Object?>;
        expect(req.method, 'POST');
        expect(req.headers['Content-Type'], startsWith('application/json'));
        return _json({'jsonrpc': '2.0', 'id': sent['id'], 'result': 42});
      });

      expect(await client.call('getblockcount'), 42);
      expect(sent['jsonrpc'], '2.0');
      expect(sent['method'], 'getblockcount');
      expect(sent['params'], isEmpty);
    });

    test('returns null results (e.g. ping)', () async {
      final client = _client((_) async => _json({'id': 1, 'result': null}));
      expect(await client.call('ping'), isNull);
    });

    test('parses error bodies even on non-200 status', () async {
      // Floresta returns 503 + JSON-RPC error during IBD.
      final client = _client(
        (_) async => _json({
          'id': 1,
          'result': null,
          'error': {'code': -32093, 'message': 'In IBD', 'data': null},
        }, 503),
      );
      await expectLater(
        client.call('rescanblockchain'),
        throwsA(
          isA<JsonRpcErrorException>().having((e) => e.code, 'code', -32093),
        ),
      );
    });

    test('treats a non-JSON 401 as a foreign service', () async {
      final client = _client((_) async => http.Response('', 401));
      await expectLater(
        client.call('getblockchaininfo'),
        throwsA(
          isA<JsonRpcHttpException>().having(
            (e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
    });

    test('rejects malformed 200 responses', () async {
      final client = _client((_) async => http.Response('not json', 200));
      await expectLater(
        client.call('getblockchaininfo'),
        throwsA(isA<JsonRpcMalformedException>()),
      );
      final noResult = _client((_) async => _json({'id': 1}));
      await expectLater(
        noResult.call('x'),
        throwsA(isA<JsonRpcMalformedException>()),
      );
    });

    test('maps socket errors to unreachable', () async {
      final client = _client(
        (_) async => throw const SocketException('Connection refused'),
      );
      await expectLater(
        client.call('ping'),
        throwsA(isA<JsonRpcUnreachableException>()),
      );
    });

    test('times out', () async {
      final client = _client(
        (_) => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.call('getpeerinfo'),
        throwsA(isA<JsonRpcTimeoutException>()),
      );
    });
  });

  group('guardRpc', () {
    test('maps each exception to a user-facing failure', () async {
      Future<Failure> failureFor(
        Future<http.Response> Function() respond,
      ) async {
        final client = _client((_) => respond());
        final r = await guardRpc(client, () => client.call('m'));
        return r.getLeft().toNullable()!;
      }

      expect(
        await failureFor(() async => throw const SocketException('x')),
        isA<RpcUnreachableFailure>().having(
          (f) => f.endpoint,
          'endpoint',
          '127.0.0.1:38332',
        ),
      );
      expect(
        await failureFor(() async => http.Response('', 401)),
        isA<RpcForeignServiceFailure>(),
      );
      expect(
        await failureFor(
          () async => _json({
            'id': 1,
            'error': {'code': -32092, 'message': 'No block filters'},
          }, 503),
        ),
        isA<RpcErrorFailure>()
            .having(
              (f) => f.title,
              'title',
              'Compact block filters are disabled',
            )
            .having((f) => f.recovery, 'recovery', isNotNull),
      );
    });

    test('maps model cast errors to malformed-response failures', () async {
      final client = _client((_) async => _json({'id': 1, 'result': 'oops'}));
      final r = await guardRpc(
        client,
        () async => (await client.call('m') as Map)['x'],
      );
      expect(r.getLeft().toNullable(), isA<RpcMalformedResponseFailure>());
    });

    test('passes successful values through', () async {
      final client = _client((_) async => _json({'id': 1, 'result': 7}));
      expect(await guardRpc(client, () => client.call('m')), const Right(7));
    });
  });
}
