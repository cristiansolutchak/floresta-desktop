import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../node/domain/node_rpc_repository.dart';
import '../domain/wallet_sync_ports.dart';

/// [ChainView] backed by florestad's own RPC: the node validated these blocks
/// itself, so it is the authority the Electrum answers are checked against.
class NodeChainView implements ChainView {
  NodeChainView(this._rpc);

  final NodeRpcRepository _rpc;

  @override
  Future<Either<Failure, ({int validatedHeight, bool ibd})>> status() async =>
      (await _rpc.getBlockchainInfo()).map(
        (i) =>
            (validatedHeight: i.validatedHeight, ibd: i.initialBlockDownload),
      );

  @override
  Future<Either<Failure, String>> blockHash(int height) =>
      _rpc.getBlockHash(height);
}
