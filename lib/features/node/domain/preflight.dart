import 'package:equatable/equatable.dart';

/// Facts gathered from the machine right before starting florestad.
/// Null means "could not be determined", which never blocks a start.
class PreflightFacts extends Equatable {
  const PreflightFacts({
    required this.rpcPort,
    required this.rpcPortFree,
    required this.electrumPort,
    required this.electrumPortFree,
    required this.dataDir,
    required this.dataDirWritable,
    required this.freeBytes,
    required this.looksLikeBitcoinCore,
  });

  final int rpcPort;
  final bool rpcPortFree;
  final int electrumPort;
  final bool electrumPortFree;

  /// The directory florestad will write to (network subdirectory included).
  final String dataDir;
  final bool? dataDirWritable;

  /// Free space on the volume holding [dataDir].
  final int? freeBytes;

  /// The directory holds Bitcoin Core data (`blocks/` + `chainstate/`, or
  /// `bitcoin.conf`). florestad must never share a data directory with it.
  final bool looksLikeBitcoinCore;

  @override
  List<Object?> get props => [
    rpcPort,
    rpcPortFree,
    electrumPort,
    electrumPortFree,
    dataDir,
    dataDirWritable,
    freeBytes,
    looksLikeBitcoinCore,
  ];
}

enum PreflightSeverity { blocking, warning }

/// Disk use of the running node's data folder, refreshed
/// periodically. Null fields mean "could not be determined".
class DiskUsage extends Equatable {
  const DiskUsage({required this.dataDir, this.usedBytes, this.freeBytes});

  final String dataDir;
  final int? usedBytes;
  final int? freeBytes;

  /// Same thresholds as the start check: below 1 GiB florestad may fail,
  /// below 5 GiB syncing may stop soon.
  PreflightSeverity? get alert => switch (freeBytes) {
    final free? when free < preflightMinFreeBytes => PreflightSeverity.blocking,
    final free? when free < preflightLowFreeBytes => PreflightSeverity.warning,
    _ => null,
  };

  @override
  List<Object?> get props => [dataDir, usedBytes, freeBytes];
}

class PreflightIssue extends Equatable {
  const PreflightIssue({
    required this.severity,
    required this.title,
    required this.message,
    this.recovery,
  });

  final PreflightSeverity severity;
  final String title;
  final String message;
  final String? recovery;

  bool get blocks => severity == PreflightSeverity.blocking;

  @override
  List<Object?> get props => [severity, title, message, recovery];
}

/// Thresholds. florestad keeps a pruned chain: a mainnet data folder
/// measured 202.2 MB at block ~940,800 with compact filters off (headers,
/// Utreexo accumulator, wallet; 2026-10-26). Compact filters add to that
/// from the wallet's start height and have not been measured on mainnet, so
/// the warning keeps a wide margin.
const preflightMinFreeBytes = 1024 * 1024 * 1024; // 1 GiB: refuse below
const preflightLowFreeBytes = 5 * 1024 * 1024 * 1024; // 5 GiB: warn below

/// Pure decision: which issues the facts raise, blocking ones first.
List<PreflightIssue> evaluatePreflight(PreflightFacts f) {
  final issues = <PreflightIssue>[
    if (!f.rpcPortFree)
      PreflightIssue(
        severity: PreflightSeverity.blocking,
        title: 'Port ${f.rpcPort} is in use',
        message:
            'Another program is using 127.0.0.1:${f.rpcPort}, the port '
            'Floresta needs for its API, and it does not answer like '
            'Floresta.',
        recovery:
            'Close the other program, or choose a different RPC port in '
            'Settings.',
      ),
    if (!f.electrumPortFree)
      PreflightIssue(
        severity: PreflightSeverity.blocking,
        title: 'Port ${f.electrumPort} is in use',
        message:
            'Another program is using 127.0.0.1:${f.electrumPort}, the port '
            'Floresta uses for its Electrum server. Floresta would exit '
            'right after starting.',
        recovery:
            'Close the other program (for example another Electrum server) '
            'and try again.',
      ),
    if (f.looksLikeBitcoinCore)
      PreflightIssue(
        severity: PreflightSeverity.blocking,
        title: 'This folder belongs to Bitcoin Core',
        message:
            '${f.dataDir} contains Bitcoin Core data. Floresta must use its '
            'own folder so neither program damages the other\'s data.',
        recovery: 'Choose an empty folder for Floresta in Settings.',
      ),
    if (f.dataDirWritable == false)
      PreflightIssue(
        severity: PreflightSeverity.blocking,
        title: 'Cannot write to the data folder',
        message: 'This app cannot create files in ${f.dataDir}.',
        recovery:
            'Choose a folder you own in Settings, or fix the folder\'s '
            'permissions.',
      ),
    if (f.freeBytes case final free? when free < preflightMinFreeBytes)
      PreflightIssue(
        severity: PreflightSeverity.blocking,
        title: 'Not enough disk space',
        message:
            'Only ${_gib(free)} is free where Floresta keeps its data. At '
            'least ${_gib(preflightMinFreeBytes)} is needed to start.',
        recovery: 'Free up space, or choose a folder on another disk.',
      )
    else if (f.freeBytes case final free? when free < preflightLowFreeBytes)
      PreflightIssue(
        severity: PreflightSeverity.warning,
        title: 'Disk space is low',
        message:
            'Only ${_gib(free)} is free where Floresta keeps its data. '
            'Syncing may stop if the disk fills up.',
        recovery: 'Free up space when you can.',
      ),
  ];
  issues.sort((a, b) => a.severity.index.compareTo(b.severity.index));
  return issues;
}

String _gib(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
