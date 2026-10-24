import 'package:fpdart/fpdart.dart';

import '../errors/failure.dart';
import 'json_rpc_client.dart';

/// Runs an RPC-backed operation and converts data-layer exceptions into
/// domain [Failure]s, so no exception crosses a repository boundary.
Future<Either<Failure, T>> guardRpc<T>(
  JsonRpcClient client,
  Future<T> Function() operation,
) async {
  try {
    return Right(await operation());
  } on JsonRpcException catch (e) {
    return Left(mapRpcException(e, client.endpoint));
  } on FormatException catch (e) {
    return Left(RpcMalformedResponseFailure('response parsing', e.message));
  } on TypeError catch (e) {
    // Thrown by model `fromJson` casts when a field has an unexpected type.
    return Left(RpcMalformedResponseFailure('response parsing', '$e'));
  }
}

Failure mapRpcException(JsonRpcException e, Uri endpoint) {
  final where = '${endpoint.host}:${endpoint.port}';
  return switch (e) {
    JsonRpcUnreachableException() => RpcUnreachableFailure(where),
    JsonRpcTimeoutException(:final timeout) => RpcTimeoutFailure(
      e.method,
      timeout,
    ),
    JsonRpcHttpException(:final statusCode) => RpcForeignServiceFailure(
      where,
      statusCode,
    ),
    JsonRpcMalformedException(:final detail) => RpcMalformedResponseFailure(
      e.method,
      detail,
    ),
    JsonRpcErrorException(:final code, :final message, :final data) =>
      RpcErrorFailure(
        method: e.method,
        code: code,
        nodeMessage: message,
        data: data,
      ),
  };
}
