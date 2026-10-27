/// Opt-in NODE-03: readiness signals from a REAL florestad on regtest.
///
///   FLORESTAD_PATH=/path/to/florestad flutter test test/integration/readiness_regtest_test.dart
///
/// Checks the Electrum identity probe against the real server (right and
/// wrong network) and that readiness reads the real RPC shapes. Isolation
/// as in florestad_regtest_test.dart.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/node/data/electrum_probe.dart';
import 'package:floresta_gui/features/node/data/florestad_process_manager.dart';
import 'package:floresta_gui/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_gui/features/node/domain/node_readiness.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final _florestad = Platform.environment['FLORESTAD_PATH'];

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  test(
    'Electrum identity and readiness from a real regtest node',
    () async {
      final temp = await Directory.systemTemp.createTemp('floresta_it_');
      addTearDown(() async {
        if (temp.path.contains('floresta_it_') && temp.existsSync()) {
          await temp.delete(recursive: true);
        }
      });
      final settings = NodeSettings(
        network: BitcoinNetwork.regtest,
        dataDir: temp.path,
        rpcPort: await _freePort(),
        logToFile: false,
      );
      final electrumPort = await _freePort();
      final deadPeer = await _freePort();
      final client = http.Client();
      addTearDown(client.close);
      final rpc = NodeRpcRepositoryImpl(
        JsonRpcClient(
          endpoint: settings.rpcEndpoint,
          httpClient: client,
          defaultTimeout: const Duration(seconds: 5),
        ),
      );
      final manager = FlorestadProcessManager(
        startProcess: (e, args) => Process.start(e, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrumPort',
          '--connect',
          '127.0.0.1:$deadPeer',
          '--disable-dns-seeds',
        ]),
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
      );
      addTearDown(manager.dispose);
      await manager.start(executablePath: _florestad!, settings: settings);

      const probe = ElectrumProbe();
      // Before the node is up nothing answers.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      var electrum = ElectrumCheck.unreachable;
      while (electrum != ElectrumCheck.ok) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Electrum never answered ($electrum)');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        electrum = await probe.check(
          BitcoinNetwork.regtest,
          port: electrumPort,
        );
      }
      expect(
        await probe.check(BitcoinNetwork.signet, port: electrumPort),
        ElectrumCheck.wrongNetwork,
        reason: 'genesis hash comparison must reject another network',
      );

      final chain = (await rpc.getBlockchainInfo()).toNullable()!;
      final peers = (await rpc.getPeers()).toNullable()!;
      final status = NodeStatus(
        process: manager.state,
        api: ApiReachability.reachable,
        chain: chain,
        peers: peers,
        lastProgressAt: DateTime.now(),
        electrum: electrum,
      );
      final readiness = assessReadiness(
        status,
        expected: BitcoinNetwork.regtest,
        now: DateTime.now(),
      );
      expect(readiness.wrongNetwork, isFalse);
      expect(
        assessReadiness(
          status,
          expected: BitcoinNetwork.signet,
          now: DateTime.now(),
        ).wrongNetwork,
        isTrue,
      );
      // ignore: avoid_print
      print(
        'regtest readiness: ${readiness.stage.name} '
        '(ibd=${chain.initialBlockDownload}, headers=${chain.headerHeight}, '
        'validated=${chain.validatedHeight}, peers=${peers.length}, '
        'electrum=${electrum.name})',
      );
      expect((await manager.stop()).isRight(), isTrue);
    },
    skip: _florestad == null
        ? 'Set FLORESTAD_PATH to a florestad binary to run this test'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
