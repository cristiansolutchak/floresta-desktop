import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'blockchain_info.dart';
import 'peer.dart';

/// Read and control operations on a running florestad, over JSON-RPC.
abstract interface class NodeRpcRepository {
  Future<Either<Failure, BlockchainInfo>> getBlockchainInfo();

  Future<Either<Failure, List<Peer>>> getPeers();

  /// Hash (display hex) of the active-chain block at [height]
  /// (`getblockhash`).
  Future<Either<Failure, String>> getBlockHash(int height);

  /// Seconds since florestad's RPC server started.
  Future<Either<Failure, Duration>> getUptime();

  /// Asks florestad to shut down gracefully (`stop`).
  Future<Either<Failure, Unit>> requestStop();

  /// `addnode <address> <add|onetry> <v2transport>` (v0.9.1
  /// `json_rpc/network.rs` `add_node`). `add` keeps reconnecting to the
  /// peer; `onetry` connects once. Manual peers bypass florestad's outgoing
  /// limit and its service check.
  Future<Either<Failure, Unit>> addNode(
    String address, {
    required AddNodeCommand command,
    bool v2transport = false,
  });

  /// `disconnectnode <address>` (v0.9.1 `json_rpc/network.rs`). The peer may
  /// connect again later; nothing is banned.
  Future<Either<Failure, Unit>> disconnectNode(String address);
}

enum AddNodeCommand { add, onetry }
