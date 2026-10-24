import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'blockchain_info.dart';
import 'peer.dart';

/// Read and control operations on a running florestad, over JSON-RPC.
abstract interface class NodeRpcRepository {
  Future<Either<Failure, BlockchainInfo>> getBlockchainInfo();

  Future<Either<Failure, List<Peer>>> getPeers();

  /// Seconds since florestad's RPC server started.
  Future<Either<Failure, Duration>> getUptime();

  /// Asks florestad to shut down gracefully (`stop`).
  Future<Either<Failure, Unit>> requestStop();
}
