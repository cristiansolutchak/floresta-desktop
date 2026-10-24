import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thrown inside the data layer only; repositories map these to `Failure`s.
sealed class JsonRpcException implements Exception {
  const JsonRpcException(this.method);
  final String method;
}

final class JsonRpcUnreachableException extends JsonRpcException {
  const JsonRpcUnreachableException(super.method, this.cause);
  final Object cause;
  @override
  String toString() => 'JsonRpcUnreachableException($method): $cause';
}

final class JsonRpcTimeoutException extends JsonRpcException {
  const JsonRpcTimeoutException(super.method, this.timeout);
  final Duration timeout;
}

/// HTTP status without a JSON-RPC body (e.g. 401 from Bitcoin Core).
final class JsonRpcHttpException extends JsonRpcException {
  const JsonRpcHttpException(super.method, this.statusCode);
  final int statusCode;
}

final class JsonRpcMalformedException extends JsonRpcException {
  const JsonRpcMalformedException(super.method, this.detail);
  final String detail;
  @override
  String toString() => 'JsonRpcMalformedException($method): $detail';
}

final class JsonRpcErrorException extends JsonRpcException {
  const JsonRpcErrorException(
    super.method, {
    required this.code,
    required this.message,
    this.data,
  });
  final int code;
  final String message;
  final String? data;
}

/// Minimal JSON-RPC 2.0 client for florestad.
///
/// Floresta's server (`crates/floresta-node/src/json_rpc/server.rs`) accepts
/// POST on `/`, has no authentication and returns non-200 HTTP codes together
/// with a JSON-RPC error body, so the body is parsed before the status code.
class JsonRpcClient {
  JsonRpcClient({
    required this.endpoint,
    required http.Client httpClient,
    this.defaultTimeout = const Duration(seconds: 10),
  }) : _http = httpClient;

  final Uri endpoint;
  final Duration defaultTimeout;
  final http.Client _http;
  int _nextId = 1;

  Future<Object?> call(
    String method, [
    List<Object?> params = const [],
    Duration? timeout,
  ]) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final id = _nextId++;
    final http.Response response;
    try {
      response = await _http
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              'params': params,
            }),
          )
          .timeout(effectiveTimeout);
    } on TimeoutException {
      throw JsonRpcTimeoutException(method, effectiveTimeout);
    } on SocketException catch (e) {
      throw JsonRpcUnreachableException(method, e);
    } on http.ClientException catch (e) {
      throw JsonRpcUnreachableException(method, e);
    }

    final Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode != 200) {
        throw JsonRpcHttpException(method, response.statusCode);
      }
      throw JsonRpcMalformedException(method, 'response is not JSON');
    }

    if (decoded is! Map<String, Object?>) {
      if (response.statusCode != 200) {
        throw JsonRpcHttpException(method, response.statusCode);
      }
      throw JsonRpcMalformedException(method, 'response is not an object');
    }

    final error = decoded['error'];
    if (error != null) {
      if (error is! Map<String, Object?>) {
        throw JsonRpcMalformedException(method, 'error is not an object');
      }
      final code = error['code'];
      final data = error['data'];
      throw JsonRpcErrorException(
        method,
        code: code is int ? code : -32603,
        message: error['message']?.toString() ?? 'Unknown error',
        data: data?.toString(),
      );
    }

    if (!decoded.containsKey('result')) {
      if (response.statusCode != 200) {
        throw JsonRpcHttpException(method, response.statusCode);
      }
      throw JsonRpcMalformedException(method, 'missing "result"');
    }
    return decoded['result'];
  }

  void close() => _http.close();
}
