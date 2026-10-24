import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../../core/rpc/rpc_failure_mapper.dart';
import '../domain/descriptor_input.dart';
import '../domain/wallet_repository.dart';

class WalletRepositoryImpl implements WalletRepository {
  WalletRepositoryImpl(this._client);

  final JsonRpcClient _client;

  @override
  Future<Either<Failure, List<String>>> listDescriptors() =>
      guardRpc(_client, () async {
        final result = await _client.call('listdescriptors') as List<Object?>;
        return [for (final d in result) d as String];
      });

  @override
  Future<Either<Failure, Unit>> loadDescriptor(DescriptorInput descriptor) =>
      guardRpc(_client, () async {
        await _client.call('loaddescriptor', [descriptor.value]);
        return unit;
      });

  @override
  Future<Either<Failure, Unit>> rescan({int? fromHeight}) =>
      guardRpc(_client, () async {
        await _client.call('rescanblockchain', [?fromHeight]);
        return unit;
      });
}
