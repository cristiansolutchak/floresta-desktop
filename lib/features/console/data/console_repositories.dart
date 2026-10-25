import 'package:fpdart/fpdart.dart';

import '../../../core/electrum/electrum_transport.dart';
import '../../../core/errors/failure.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../../core/rpc/rpc_failure_mapper.dart';
import '../domain/console_repository.dart';

/// Console calls over florestad's JSON-RPC (always on loopback).
class RpcConsoleRepository implements ConsoleRepository {
  RpcConsoleRepository(this._client);

  final JsonRpcClient _client;

  /// `rescanblockchain` and `getblockfrompeer` can take a while to answer.
  static const timeout = Duration(seconds: 60);

  @override
  String get endpoint => _client.endpoint.toString();

  @override
  Future<Either<Failure, Object?>> call(String method, List<Object?> params) =>
      guardRpc(_client, () => _client.call(method, params, timeout));
}

/// Console calls to florestad's Electrum server, one connection per call so
/// nothing stays subscribed.
class ElectrumConsoleRepository implements ConsoleRepository {
  ElectrumConsoleRepository({
    required this.host,
    required this.port,
    SocketConnector? connector,
  }) : _connector = connector;

  final String host;
  final int port;
  final SocketConnector? _connector;

  @override
  String get endpoint => 'tcp://$host:$port';

  @override
  Future<Either<Failure, Object?>> call(
    String method,
    List<Object?> params,
  ) async {
    final transport = ElectrumTransport(
      host: host,
      port: port,
      connector: _connector,
    );
    try {
      await transport.connect();
      return Right(await transport.request(method, params));
    } on ElectrumServerException catch (e) {
      return Left(ElectrumServerErrorFailure(method, e.code, e.message));
    } on ElectrumConnectionException catch (e) {
      return Left(ElectrumUnavailableFailure('$host:$port', e.detail));
    } on ElectrumTimeoutException catch (e) {
      return Left(ElectrumUnavailableFailure('$host:$port', '$e'));
    } on ElectrumProtocolException catch (e) {
      return Left(ElectrumProtocolFailure(method, e.detail));
    } finally {
      await transport.dispose();
    }
  }
}
