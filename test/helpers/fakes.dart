import 'dart:async';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/logging/log_buffer.dart';
import 'package:floresta_gui/features/installation/domain/installation.dart';
import 'package:floresta_gui/features/installation/domain/installation_repository.dart';
import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_process_manager.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/data/electrum_probe.dart';
import 'package:floresta_gui/features/node/data/preflight_probe.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_gui/features/node/domain/preflight.dart';
import 'package:floresta_gui/features/node/domain/peer.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:floresta_gui/features/wallet/domain/descriptor_input.dart';
import 'package:floresta_gui/features/wallet/domain/wallet_repository.dart';
import 'package:fpdart/fpdart.dart';

class FakeInstallationRepository implements InstallationRepository {
  FakeInstallationRepository(this.result);
  Either<Failure, FlorestaInstallation> result;
  int calls = 0;

  @override
  Future<Either<Failure, FlorestaInstallation>> detect({
    String? configuredPath,
  }) async {
    calls++;
    return result;
  }
}

class FakeNodeRpcRepository implements NodeRpcRepository {
  Either<Failure, BlockchainInfo> info = const Left(
    RpcUnreachableFailure('127.0.0.1:38332'),
  );
  List<Peer> peers = const [];
  int stopRequests = 0;
  final addNodeCalls = <(String, AddNodeCommand, bool)>[];
  final disconnected = <String>[];

  @override
  Future<Either<Failure, Unit>> disconnectNode(String address) async {
    disconnected.add(address);
    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> addNode(
    String address, {
    required AddNodeCommand command,
    bool v2transport = false,
  }) async {
    addNodeCalls.add((address, command, v2transport));
    return const Right(unit);
  }

  @override
  Future<Either<Failure, BlockchainInfo>> getBlockchainInfo() async => info;

  @override
  Future<Either<Failure, List<Peer>>> getPeers() async => Right(peers);

  final blockHashes = <int, String>{};

  @override
  Future<Either<Failure, String>> getBlockHash(int height) async =>
      blockHashes.containsKey(height)
      ? Right(blockHashes[height]!)
      : const Left(RpcUnreachableFailure('127.0.0.1:38332'));

  @override
  Future<Either<Failure, Duration>> getUptime() async =>
      const Right(Duration(minutes: 5));

  @override
  Future<Either<Failure, Unit>> requestStop() async {
    stopRequests++;
    return const Right(unit);
  }
}

class FakeProcessManager implements NodeProcessManager {
  final _states = StreamController<NodeProcessState>.broadcast();
  final starts = <(String, NodeSettings)>[];

  @override
  NodeProcessState state = const ProcessIdle();

  void emit(NodeProcessState s) {
    state = s;
    _states.add(s);
  }

  @override
  Stream<NodeProcessState> get states => _states.stream;

  /// Daemon output the app shows (Logs screen).
  @override
  List<LogLine> logs = const [];
  @override
  Stream<LogLine> get logLines => const Stream.empty();

  @override
  Future<Either<Failure, Unit>> start({
    required String executablePath,
    required NodeSettings settings,
  }) async {
    starts.add((executablePath, settings));
    emit(ProcessRunning(1, DateTime(2026)));
    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> stop() async {
    emit(const ProcessStopped(0));
    return const Right(unit);
  }

  /// When set, [reattach] adopts this state (as after an app restart).
  NodeProcessState? adoptable;

  @override
  Future<bool> reattach() async {
    final s = adoptable;
    if (s == null) return false;
    emit(s);
    return true;
  }

  @override
  Future<void> dispose() => _states.close();
}

/// Returns scripted facts instead of probing this machine.
class FakePreflightProbe extends PreflightProbe {
  FakePreflightProbe([PreflightFacts? facts])
    : facts =
          facts ??
          const PreflightFacts(
            rpcPort: 38332,
            rpcPortFree: true,
            electrumPort: 60001,
            electrumPortFree: true,
            dataDir: '/Users/a/.floresta/signet',
            dataDirWritable: true,
            freeBytes: 100 * 1024 * 1024 * 1024,
            looksLikeBitcoinCore: false,
          ),
      super(homeDir: '/Users/a');

  PreflightFacts facts;

  @override
  Future<PreflightFacts> gather(NodeSettings settings) async => facts;
}

class FakeWalletRepository implements WalletRepository {
  Either<Failure, List<String>> descriptors = const Right([]);
  final loaded = <String>[];

  @override
  Future<Either<Failure, List<String>>> listDescriptors() async => descriptors;

  @override
  Future<Either<Failure, Unit>> loadDescriptor(DescriptorInput d) async {
    loaded.add(d.value);
    // Like florestad: a loaded descriptor is listed from then on.
    descriptors = descriptors.map((l) => [...l, d.value]);
    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> rescan({int? fromHeight}) async =>
      const Right(unit);
}

/// Returns a scripted Electrum identity instead of opening a socket.
class FakeElectrumProbe extends ElectrumProbe {
  FakeElectrumProbe([this.result = ElectrumCheck.ok]);
  ElectrumCheck result;
  int checks = 0;

  @override
  Future<ElectrumCheck> check(BitcoinNetwork network, {int? port}) async {
    checks++;
    return result;
  }
}
