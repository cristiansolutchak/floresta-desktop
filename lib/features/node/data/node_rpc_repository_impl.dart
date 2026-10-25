import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../../core/rpc/rpc_failure_mapper.dart';
import '../domain/blockchain_info.dart';
import '../domain/node_rpc_repository.dart';
import '../domain/peer.dart';
import 'rpc_models.dart';

class NodeRpcRepositoryImpl implements NodeRpcRepository {
  NodeRpcRepositoryImpl(this._client);

  final JsonRpcClient _client;

  @override
  Future<Either<Failure, BlockchainInfo>> getBlockchainInfo() => guardRpc(
    _client,
    () async =>
        RpcModels.blockchainInfo(await _client.call('getblockchaininfo')),
  );

  @override
  Future<Either<Failure, List<Peer>>> getPeers() => guardRpc(
    _client,
    () async => RpcModels.peers(await _client.call('getpeerinfo')),
  );

  @override
  Future<Either<Failure, String>> getBlockHash(int height) => guardRpc(
    _client,
    () async => (await _client.call('getblockhash', [height])) as String,
  );

  @override
  Future<Either<Failure, Duration>> getUptime() => guardRpc(
    _client,
    () async =>
        Duration(seconds: (await _client.call('uptime') as num).toInt()),
  );

  @override
  Future<Either<Failure, Unit>> requestStop() => guardRpc(_client, () async {
    await _client.call('stop', const [], const Duration(seconds: 5));
    return unit;
  });

  @override
  Future<Either<Failure, Unit>> addNode(
    String address, {
    required AddNodeCommand command,
    bool v2transport = false,
  }) => guardRpc(_client, () async {
    await _client.call('addnode', [
      address,
      command.name,
      v2transport,
    ], const Duration(seconds: 10));
    return unit;
  });

  @override
  Future<Either<Failure, Unit>> disconnectNode(String address) =>
      guardRpc(_client, () async {
        await _client.call('disconnectnode', [
          address,
        ], const Duration(seconds: 10));
        return unit;
      });
}
