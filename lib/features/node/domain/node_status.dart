import 'package:equatable/equatable.dart';

import '../../../core/errors/failure.dart';
import 'blockchain_info.dart';
import 'node_process_state.dart';
import 'node_readiness.dart';
import 'preflight.dart';
import 'peer.dart';

enum ApiReachability { unknown, reachable, unreachable }

/// Everything the UI shows about the node.
///
/// Three independent facts, each with its own source:
/// * [process] — the child process this app supervises (OS process events).
/// * [api] — whether JSON-RPC answers at the configured endpoint.
/// * [chain] — sync state from `getblockchaininfo`.
/// A running process with an unreachable API is normal while florestad
/// starts; a reachable API with an idle process means another program
/// started the node.
class NodeStatus extends Equatable {
  const NodeStatus({
    this.process = const ProcessIdle(),
    this.api = ApiReachability.unknown,
    this.chain,
    this.peers,
    this.uptime,
    this.lastRpcFailure,
    this.lastUpdated,
    this.preflightWarnings = const [],
    this.lastProgressAt,
    this.electrum = ElectrumCheck.unknown,
  });

  final NodeProcessState process;
  final ApiReachability api;
  final BlockchainInfo? chain;
  final List<Peer>? peers;
  final Duration? uptime;
  final Failure? lastRpcFailure;
  final DateTime? lastUpdated;

  /// Non-blocking findings from the last start (e.g. low disk space).
  final List<PreflightIssue> preflightWarnings;

  /// Last time the header or validated height moved (or the node came up).
  final DateTime? lastProgressAt;

  /// Latest Electrum identity check.
  final ElectrumCheck electrum;

  bool get isExternallyManaged =>
      !process.isActive && api == ApiReachability.reachable;

  bool get canStart => !process.isActive && api != ApiReachability.reachable;

  bool get canStop =>
      process is ProcessRunning ||
      process is ProcessAdopted ||
      process is ProcessStarting ||
      isExternallyManaged;

  NodeStatus copyWith({
    NodeProcessState? process,
    ApiReachability? api,
    BlockchainInfo? chain,
    List<Peer>? peers,
    Duration? uptime,
    Failure? lastRpcFailure,
    bool clearChain = false,
    bool clearFailure = false,
    DateTime? lastUpdated,
    List<PreflightIssue>? preflightWarnings,
    DateTime? lastProgressAt,
    ElectrumCheck? electrum,
  }) {
    return NodeStatus(
      process: process ?? this.process,
      api: api ?? this.api,
      chain: clearChain ? null : chain ?? this.chain,
      peers: clearChain ? null : peers ?? this.peers,
      uptime: clearChain ? null : uptime ?? this.uptime,
      lastRpcFailure: clearFailure
          ? null
          : lastRpcFailure ?? this.lastRpcFailure,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      preflightWarnings: preflightWarnings ?? this.preflightWarnings,
      lastProgressAt: clearChain ? null : lastProgressAt ?? this.lastProgressAt,
      electrum: clearChain ? ElectrumCheck.unknown : electrum ?? this.electrum,
    );
  }

  @override
  List<Object?> get props => [
    process,
    api,
    chain,
    peers,
    uptime,
    lastRpcFailure,
    lastUpdated,
    preflightWarnings,
    lastProgressAt,
    electrum,
  ];
}
