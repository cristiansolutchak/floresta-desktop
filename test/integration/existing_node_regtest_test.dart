/// Opt-in: "connect to a node that is already running" against REAL nodes.
///
///   FLORESTAD_PATH=/abs/florestad \
///   FLORESTAD_LINUX_PATH=/abs/florestad-linux-ARCH \
///   flutter test test/integration/existing_node_regtest_test.dart
///
/// 1. A real florestad on regtest, started outside the app (like one in a
///    terminal or a Nix service): ExistingNodeProbe must accept it on
///    regtest and refuse it as signet.
/// 2. With Docker and FLORESTAD_LINUX_PATH: the same binary in a real
///    container, published on 127.0.0.1 and then on every interface.
///    DockerProbe must list it, see the port, and flag the second binding.
///
/// Nodes use temp data dirs, free loopback ports, and `--connect` to a
/// closed port, so they never reach another node or the internet.
/// Containers are removed afterwards.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/platform/host_platform.dart';
import 'package:floresta_gui/features/installation/data/existing_node_probe.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _florestad = Platform.environment['FLORESTAD_PATH'];
final _linuxFlorestad = Platform.environment['FLORESTAD_LINUX_PATH'];

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<void> _waitForRpc(ExistingNodeProbe probe, int port) async {
  final end = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(end)) {
    if ((await probe.check(BitcoinNetwork.regtest, port)).rpc.isRight()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('no RPC on $port within 90 s');
}

String? _docker() {
  for (final p in [
    '/usr/local/bin/docker',
    '/opt/homebrew/bin/docker',
    '/usr/bin/docker',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  final http = _client();
  tearDownAll(http.close);

  test(
    'a node started outside the app is checked, not assumed',
    () async {
      final temp = Directory.systemTemp.createTempSync('existing_node_');
      final rpc = await _freePort();
      final closed = await _freePort();
      final node = await Process.start(_florestad!, [
        '--network',
        'regtest',
        '--data-dir',
        temp.path,
        '--rpc-address',
        '127.0.0.1:$rpc',
        '--electrum-address',
        '127.0.0.1:${await _freePort()}',
        '--connect',
        '127.0.0.1:$closed',
      ]);
      addTearDown(() async {
        node.kill(ProcessSignal.sigint);
        await node.exitCode.timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            node.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        temp.deleteSync(recursive: true);
      });
      node.stdout.drain<void>();
      node.stderr.drain<void>();

      final probe = ExistingNodeProbe(httpClient: http);
      await _waitForRpc(probe, rpc);
      final ok = await probe.check(BitcoinNetwork.regtest, rpc);
      expect(ok.rpc.isRight(), isTrue);
      final wrong = await probe.check(BitcoinNetwork.signet, rpc);
      expect(wrong.rpc.getLeft().toNullable(), isA<ChainMismatchFailure>());
      final nothing = await probe.check(BitcoinNetwork.regtest, closed);
      expect(nothing.rpc.isLeft(), isTrue);
    },
    skip: _florestad == null ? 'set FLORESTAD_PATH' : null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  final docker = _docker();
  test(
    'a node in Docker is found, and an exposed RPC is flagged',
    () async {
      final probe = ExistingNodeProbe(httpClient: http);
      final dockerProbe = DockerProbe(
        platform: HostPlatform.current(),
        environment: Platform.environment,
      );
      final bin = File(_linuxFlorestad!).parent.path;
      final name = File(_linuxFlorestad!).uri.pathSegments.last;

      Future<(String, int)> run(String bind) async {
        final port = await _freePort();
        final container = 'floresta-gui-test-${bind.replaceAll('.', '')}';
        await Process.run(docker!, ['rm', '-f', container]);
        final r = await Process.run(docker, [
          'run',
          '-d',
          '--name',
          container,
          '-p',
          '$bind:$port:$port',
          '-v',
          '$bin:/f:ro',
          'debian:bookworm',
          '/f/$name',
          '--network',
          'regtest',
          '--data-dir',
          '/tmp/data',
          '--rpc-address',
          '0.0.0.0:$port',
          '--connect',
          '127.0.0.1:1',
        ]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        addTearDown(() => Process.run(docker, ['rm', '-f', container]));
        return (container, port);
      }

      final (loopName, loopPort) = await run('127.0.0.1');
      final (openName, openPort) = await run('0.0.0.0');
      await _waitForRpc(probe, loopPort);
      await _waitForRpc(probe, openPort);

      final scan = await dockerProbe.scan();
      expect(scan, isA<DockerContainers>(), reason: '$scan');
      final found = {
        for (final c in (scan as DockerContainers).containers) c.name: c,
      };
      expect(found[loopName]!.running, isTrue);
      expect(found[loopName]!.onHostPort(loopPort)!.onAllInterfaces, isFalse);
      expect(found[openName]!.onHostPort(openPort)!.onAllInterfaces, isTrue);
      expect(
        (await probe.check(BitcoinNetwork.regtest, loopPort)).rpc.isRight(),
        isTrue,
      );
    },
    skip: _linuxFlorestad == null || docker == null
        ? 'set FLORESTAD_LINUX_PATH and install Docker'
        : null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

http.Client _client() => http.Client();
