import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;

import '../../../core/errors/failure.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/processes/process_starter.dart';
import '../../../core/rpc/json_rpc_client.dart';
import '../../node/data/electrum_probe.dart';
import '../../node/data/node_rpc_repository_impl.dart';
import '../../node/domain/blockchain_info.dart';
import '../../node/domain/node_readiness.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../domain/existing_node.dart';
import 'executable_locator.dart' show isExecutableFile;

/// What Docker says, when Docker is on this computer.
sealed class DockerScan {
  const DockerScan();
}

/// No docker command was found, so nothing was asked.
final class DockerNotFound extends DockerScan {
  const DockerNotFound();
}

/// `docker ps` failed: the daemon is not running, or permission was denied.
final class DockerUnavailable extends DockerScan {
  const DockerUnavailable(this.detail);
  final String detail;
}

final class DockerContainers extends DockerScan {
  const DockerContainers(this.containers);

  /// Only containers that look like Floresta.
  final List<DockerContainer> containers;
}

/// Lists Docker containers with one fixed, read-only command:
/// `docker ps --all --format {{json .}}` (no shell, 5 s timeout).
class DockerProbe {
  DockerProbe({
    required this.platform,
    required this.environment,
    ProcessStarter? startProcess,
    Future<bool> Function(String path)? isExecutable,
    this.timeout = const Duration(seconds: 5),
  }) : _start = startProcess ?? startSystemProcess,
       _isExecutable = isExecutable ?? isExecutableFile;

  final HostPlatform platform;
  final Map<String, String> environment;
  final ProcessStarter _start;
  final Future<bool> Function(String path) _isExecutable;
  final Duration timeout;

  /// Where the docker command lives: PATH first, then the places Docker
  /// Desktop, Homebrew, OrbStack and distribution packages put it (apps
  /// opened from Finder do not inherit the shell's PATH).
  List<String> candidates() {
    final windows = platform.os == HostOs.windows;
    final name = windows ? 'docker.exe' : 'docker';
    final sep = platform.pathSeparator;
    final home = environment[windows ? 'USERPROFILE' : 'HOME'];
    final dirs = [
      ...(environment['PATH'] ?? environment['Path'] ?? '').split(
        platform.pathListSeparator,
      ),
      if (platform.os == HostOs.macos) ...[
        '/usr/local/bin',
        '/opt/homebrew/bin',
        '/Applications/Docker.app/Contents/Resources/bin',
        if (home != null) '$home/.docker/bin',
        if (home != null) '$home/.orbstack/bin',
      ],
      if (platform.os == HostOs.linux) ...['/usr/bin', '/usr/local/bin'],
      if (windows) r'C:\Program Files\Docker\Docker\resources\bin',
    ];
    final seen = <String>{};
    return [
      for (final d in dirs)
        if (d.isNotEmpty && seen.add(d)) '$d$sep$name',
    ];
  }

  Future<DockerScan> scan() async {
    String? docker;
    for (final c in candidates()) {
      if (await _isExecutable(c)) {
        docker = c;
        break;
      }
    }
    if (docker == null) return const DockerNotFound();
    final Process process;
    try {
      process = await _start(docker, const [
        'ps',
        '--all',
        '--format',
        '{{json .}}',
      ]);
    } on ProcessException catch (e) {
      return DockerUnavailable(e.message);
    }
    unawaited(process.stdin.close().catchError((_) {}));
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return const DockerUnavailable('Docker did not answer in time.');
    }
    if (code != 0) {
      final detail = (await err).trim();
      return DockerUnavailable(
        detail.isEmpty ? 'docker ps exited with code $code.' : detail,
      );
    }
    return DockerContainers([
      for (final c in parseDockerPs(await out))
        if (c.looksLikeFloresta) c,
    ]);
  }
}

/// The answer from the node on 127.0.0.1:[rpcPort].
typedef ExistingNodeCheck = ({
  Either<Failure, BlockchainInfo> rpc,
  ElectrumCheck electrum,
});

/// Checks a node that runs elsewhere before the app is set to use it: its
/// RPC must answer as Floresta on the expected network, and its Electrum
/// server is checked the same way the dashboard does.
class ExistingNodeProbe {
  ExistingNodeProbe({required this.httpClient, ElectrumProbe? electrum})
    : _electrum = electrum ?? const ElectrumProbe();

  final http.Client httpClient;
  final ElectrumProbe _electrum;

  Future<ExistingNodeCheck> check(BitcoinNetwork network, int rpcPort) async {
    final client = JsonRpcClient(
      endpoint: Uri.parse('http://127.0.0.1:$rpcPort/'),
      httpClient: httpClient,
    );
    final rpc = (await NodeRpcRepositoryImpl(client).getBlockchainInfo())
        .flatMap<BlockchainInfo>(
          (info) => info.network == network
              ? Right(info)
              : Left(
                  ChainMismatchFailure(
                    'The node at 127.0.0.1:$rpcPort follows '
                    '${info.network?.label ?? info.chain}, not '
                    '${network.label}.',
                  ),
                ),
        );
    final electrum = rpc.isRight()
        ? await _electrum.check(network)
        : ElectrumCheck.unreachable;
    return (rpc: rpc, electrum: electrum);
  }
}
