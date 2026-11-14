import 'dart:convert';
import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/features/installation/data/existing_node_probe.dart';
import 'package:floresta_gui/features/installation/domain/existing_node.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/fake_process.dart';
import '../../helpers/fakes.dart';
import '../node/node_rpc_test.dart'
    show blockchainInfoJson, signetAfterSnapshot;

/// Shaped like `docker ps --all --format '{{json .}}'` (Docker 27), for the
/// compose file in upstream doc/docker.md and a container published only on
/// loopback.
const _ps =
    '{"Command":"\\"florestad -c /dat…\\"","Image":"dlsz/floresta:latest",'
    '"Names":"Floresta","Ports":"0.0.0.0:8332->8332/tcp, :::8332->8332/tcp, '
    '0.0.0.0:50001->50001/tcp, :::50001->50001/tcp","State":"running",'
    '"Status":"Up 2 hours"}\n'
    '{"Command":"\\"florestad --network…\\"","Image":"floresta-local",'
    '"Names":"floresta-signet","Ports":"127.0.0.1:38332->38332/tcp, '
    '50001/tcp","State":"exited","Status":"Exited (0) 3 days ago"}\n'
    '{"Command":"\\"postgres\\"","Image":"postgres:16","Names":"db",'
    '"Ports":"5432/tcp","State":"running","Status":"Up 1 hour"}\n'
    'WARNING: not json\n';

void main() {
  group('docker ps parsing', () {
    test('reads containers and published TCP ports', () {
      final all = parseDockerPs(_ps);
      expect(all.map((c) => c.name), ['Floresta', 'floresta-signet', 'db']);
      final up = all.first;
      expect(up.running, isTrue);
      expect(up.looksLikeFloresta, isTrue);
      expect(up.ports, hasLength(4));
      expect(up.onHostPort(8332)!.onAllInterfaces, isTrue);
      expect(all[1].running, isFalse);
      expect(all[1].onHostPort(38332)!.onAllInterfaces, isFalse);
      // "50001/tcp" is exposed but not published, so it is not listed.
      expect(all[1].ports, hasLength(1));
      expect(all[2].looksLikeFloresta, isFalse);
    });

    test('parses IPv4, IPv6 and bracketed bindings', () {
      expect(parseDockerPorts('[::]:8332->8332/tcp'), [
        const PublishedPort(
          hostAddress: '::',
          hostPort: 8332,
          containerPort: 8332,
        ),
      ]);
      expect(parseDockerPorts('127.0.0.1:18442->18442/tcp, 53/udp'), [
        const PublishedPort(
          hostAddress: '127.0.0.1',
          hostPort: 18442,
          containerPort: 18442,
        ),
      ]);
      expect(parseDockerPorts(''), isEmpty);
    });
  });

  group('DockerProbe', () {
    const mac = HostPlatform(HostOs.macos, CpuArch.arm64);

    test('looks on PATH, then where Docker Desktop and OrbStack put it', () {
      final probe = DockerProbe(
        platform: mac,
        environment: const {'PATH': '/usr/bin', 'HOME': '/Users/a'},
      );
      expect(probe.candidates(), [
        '/usr/bin/docker',
        '/usr/local/bin/docker',
        '/opt/homebrew/bin/docker',
        '/Applications/Docker.app/Contents/Resources/bin/docker',
        '/Users/a/.docker/bin/docker',
        '/Users/a/.orbstack/bin/docker',
      ]);
    });

    test('no docker command: nothing is run', () async {
      var started = 0;
      final scan = await DockerProbe(
        platform: mac,
        environment: const {'PATH': '/usr/bin'},
        isExecutable: (_) async => false,
        startProcess: (_, _) async {
          started++;
          return FakeProcess();
        },
      ).scan();
      expect(scan, isA<DockerNotFound>());
      expect(started, 0);
    });

    test('runs one fixed read-only command and keeps Floresta only', () async {
      final calls = <(String, List<String>)>[];
      final scan = await DockerProbe(
        platform: mac,
        environment: const {'PATH': '/usr/bin'},
        isExecutable: (p) async => p == '/usr/local/bin/docker',
        startProcess: (exe, args) async {
          calls.add((exe, args));
          final p = FakeProcess();
          for (final line in const LineSplitter().convert(_ps)) {
            p.emitStdout(line);
          }
          // Exits once the probe listens (closing waits for a listener).
          Future<void>.delayed(Duration.zero, () => p.exit(0));
          return p;
        },
      ).scan();
      expect(calls.single.$1, '/usr/local/bin/docker');
      expect(calls.single.$2, ['ps', '--all', '--format', '{{json .}}']);
      expect((scan as DockerContainers).containers.map((c) => c.name), [
        'Floresta',
        'floresta-signet',
      ]);
    });

    test('a stopped daemon is reported, not hidden', () async {
      final scan = await DockerProbe(
        platform: mac,
        environment: const {'PATH': '/usr/bin'},
        isExecutable: (p) async => p == '/usr/bin/docker',
        startProcess: (_, _) async {
          final p = FakeProcess();
          p.emitStderr('Cannot connect to the Docker daemon.');
          Future<void>.delayed(Duration.zero, () => p.exit(1));
          return p;
        },
      ).scan();
      expect(
        (scan as DockerUnavailable).detail,
        'Cannot connect to the Docker daemon.',
      );
    });

    test('a hung docker is killed after the timeout', () async {
      final process = FakeProcess(onSignal: (_) => 137);
      final scan = await DockerProbe(
        platform: mac,
        environment: const {'PATH': '/usr/bin'},
        isExecutable: (p) async => p == '/usr/bin/docker',
        startProcess: (_, _) async => process,
        timeout: const Duration(milliseconds: 20),
      ).scan();
      expect(scan, isA<DockerUnavailable>());
      expect(process.signals, [ProcessSignal.sigkill]);
    });
  });

  group('ExistingNodeProbe', () {
    ExistingNodeProbe probe(
      Object? info, {
      int status = 200,
      ElectrumCheck electrum = ElectrumCheck.ok,
    }) => ExistingNodeProbe(
      electrum: FakeElectrumProbe(electrum),
      httpClient: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode({'id': body['id'], 'result': info}),
          status,
        );
      }),
    );

    test('a Floresta node on the expected network passes', () async {
      final r = await probe(
        signetAfterSnapshot,
      ).check(BitcoinNetwork.signet, 38332);
      expect(r.rpc.isRight(), isTrue);
      expect(r.electrum, ElectrumCheck.ok);
    });

    test('another network is refused, and Electrum is not asked', () async {
      // A signet node where the user expects regtest.
      final r = await probe(
        blockchainInfoJson(),
        electrum: ElectrumCheck.ok,
      ).check(BitcoinNetwork.regtest, 18442);
      expect(r.rpc.getLeft().toNullable(), isA<ChainMismatchFailure>());
      expect(r.electrum, ElectrumCheck.unreachable);
    });

    test('something else on the port is not taken for Floresta', () async {
      final r = await probe(
        null,
        status: 401,
      ).check(BitcoinNetwork.bitcoin, 8332);
      expect(r.rpc.isLeft(), isTrue);
    });
  });
}
