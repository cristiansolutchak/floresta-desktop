/// Opt-in, REAL binaries: why chain selection hangs, and that the app's fix
/// (drop the peer that will not answer) ends it.
///
///   source the env file from tool/regtest/bootstrap.sh, then
///   flutter test test/integration/chain_selection_regtest_test.dart
///
/// florestad v0.9.1 leaves chain selection only when every peer answered
/// `getheaders` with an empty `headers` (`chain_selector_ctx.rs`
/// `LookingForForks`); a utreexod that is not in sync ignores `getheaders`
/// (utreexod v0.5.2 `server.go` `OnGetHeaders`). Here a fresh utreexod at
/// genesis plays the mainnet utreexod that was 3 000 blocks behind. It
/// checks, with the app's
/// own process manager, log buffer and RPC client:
///
/// 1. the selection start and end lines the app reads are the ones florestad
///    prints ([selectionPhaseFromLogs]);
/// 2. with that utreexod connected, selection does not end even though
///    bitcoind gave every header;
/// 3. once the app drops it the way the app does ([dropPeer]: off
///    florestad's reconnect list, then disconnected), selection ends and the
///    node validates the chain. A bare `disconnectnode` is not enough: the
///    peer was added with `addnode add`, and florestad reconnected it
///    within 10 s (first run of this test). Validation then needs a
///    Utreexo peer again: the utreexod syncs from bitcoind and is re-added,
///    as the app's finder does once selection is over.
///
/// Everything is regtest on loopback in a temp dir.
@Tags(['integration'])
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:floresta_desktop/core/rpc/json_rpc_client.dart';
import 'package:floresta_desktop/features/node/data/florestad_process_manager.dart';
import 'package:floresta_desktop/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_desktop/features/node/data/utreexo_peer_finder.dart';
import 'package:floresta_desktop/features/node/domain/node_rpc_repository.dart';
import 'package:floresta_desktop/features/node/domain/utreexo_peer.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/regtest_cluster.dart';

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  final env = Platform.environment;
  final missing = RegtestCluster.missingTools;

  test(
    'a peer that ignores getheaders holds selection; dropping it ends it',
    () async {
      final root = await Directory.systemTemp.createTemp('floresta_select_');
      final client = http.Client();
      final spawned = <Process>[];
      Future<Process> spawn(String name, String exe, List<String> args) async {
        final p = await Process.start(exe, args);
        final log = File('${root.path}/$name.log').openWrite();
        p.stdout.listen(log.add);
        p.stderr.listen(log.add);
        spawned.add(p);
        return p;
      }

      FlorestadProcessManager? florestad;
      addTearDown(() async {
        try {
          await florestad?.dispose();
        } catch (_) {}
        for (final p in spawned.reversed) {
          p.kill(ProcessSignal.sigint);
        }
        for (final p in spawned) {
          await p.exitCode.timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              p.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
        client.close();
        await root.delete(recursive: true);
      });

      // bitcoind with a mined chain: answers getheaders.
      final coreRpc = await _freePort(), coreP2p = await _freePort();
      await spawn('bitcoind', env['BITCOIND_PATH']!, [
        '-regtest',
        '-datadir=${(Directory('${root.path}/core')..createSync()).path}',
        '-port=$coreP2p',
        '-bind=127.0.0.1:$coreP2p',
        '-rpcport=$coreRpc',
        '-rpcbind=127.0.0.1',
        '-rpcallowip=127.0.0.1',
        '-rpcuser=test',
        '-rpcpassword=test',
        '-listen=1',
        '-dnsseed=0',
        '-fixedseeds=0',
        '-connect=0',
        '-v2transport=0',
      ]);
      final core = CoreRpc(client, coreRpc);
      await waitFor(
        'bitcoind',
        () async => (await core.call('getblockcount')) is int,
      );
      expect((await core.call('getblockchaininfo') as Map)['chain'], 'regtest');
      await core.call('createwallet', ['miner']);
      final to = await core.call('getnewaddress', [], 'miner') as String;
      await core.call('generatetoaddress', [120, to]);

      // A utreexod at genesis, connected to nobody: not "current", so it
      // ignores getheaders, like the mainnet one 3 000 blocks behind.
      final utxRpc = await _freePort(), utxP2p = await _freePort();
      final conf = File('${root.path}/utreexod.conf')..writeAsStringSync('');
      await spawn('utreexod', env['UTREEXOD_PATH']!, [
        '--configfile=${conf.path}',
        '--regtest',
        '--datadir=${root.path}/utreexod',
        '--logdir=${root.path}/utreexod',
        '--listen=127.0.0.1:$utxP2p',
        '--rpclisten=127.0.0.1:$utxRpc',
        '--notls',
        '--rpcuser=test',
        '--rpcpass=test',
        '--nodnsseed',
        // A proof-serving bridge, as in RegtestCluster; with no peers it
        // stays at genesis, so not "current".
        '--noutreexo',
        '--flatutreexoproofindex',
        '--prune=0',
      ]);
      final utx = CoreRpc(client, utxRpc);
      await waitFor(
        'utreexod',
        () async => await utx.call('getblockcount') == 0,
      );

      // florestad through the app's process manager; no fixed peer, so the
      // app's addnode decides who it talks to.
      final floRpc = await _freePort();
      final settings = NodeSettings(
        network: BitcoinNetwork.regtest,
        dataDir: '${root.path}/florestad',
        rpcPort: floRpc,
        logToFile: false,
      );
      final rpc = NodeRpcRepositoryImpl(
        JsonRpcClient(endpoint: settings.rpcEndpoint, httpClient: client),
      );
      final electrum = await _freePort();
      florestad = FlorestadProcessManager(
        startProcess: (exe, args) => Process.start(exe, [
          ...args,
          '--electrum-address',
          '127.0.0.1:$electrum',
          '--disable-dns-seeds',
        ]),
        requestGracefulStop: (_) async => (await rpc.requestStop()).isRight(),
      );
      final manager = florestad;
      SelectionPhase phase() =>
          selectionPhaseFromLogs([for (final l in manager.logs) l.text]);

      final started = await manager.start(
        executablePath: env['FLORESTAD_PATH']!,
        settings: settings,
      );
      expect(started.isRight(), isTrue, reason: '$started');
      await waitFor('selection start line', () async {
        return phase() == SelectionPhase.selecting;
      });

      // The blocking peer first, then the one with the chain.
      final utxAddr = '127.0.0.1:$utxP2p';
      expect(
        (await rpc.addNode(utxAddr, command: AddNodeCommand.add)).isRight(),
        isTrue,
      );
      expect(
        (await rpc.addNode(
          '127.0.0.1:$coreP2p',
          command: AddNodeCommand.add,
        )).isRight(),
        isTrue,
      );
      await waitFor('all 120 headers', () async {
        final info = (await rpc.getBlockchainInfo()).toNullable();
        return info != null && info.headerHeight == 120;
      }, timeout: const Duration(seconds: 90));

      // 2. Held: all headers, both peers connected, but selection does not
      // end over two and a half re-ask rounds (florestad re-asks every 60 s).
      final heldSince = DateTime.now();
      while (DateTime.now().difference(heldSince) <
          const Duration(seconds: 150)) {
        expect(phase(), SelectionPhase.selecting);
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      final peers = (await rpc.getPeers()).toNullable() ?? const [];
      expect(peers.map((p) => p.address), contains(utxAddr));
      final held = (await rpc.getBlockchainInfo()).toNullable()!;
      expect(held.validatedHeight, 0);

      // 3. The app drops it: selection ends and the chain is validated.
      final dropAt = DateTime.now();
      // As the app does (it added this peer with `addnode add`): off the
      // reconnect list, then disconnected. A bare disconnect is not enough:
      // florestad reconnects an added peer within seconds.
      await dropPeer(rpc, utxAddr, addedByApp: true);
      await waitFor(
        'selection end line',
        () async => phase() == SelectionPhase.done,
        timeout: const Duration(seconds: 120),
      );
      final endedAfter = DateTime.now().difference(dropAt);
      // After selection, the app's finder adds Utreexo peers again; by
      // then this one has synced (as the mainnet one serves the blocks it
      // has), so it serves the proofs florestad validates with.
      await utx.call('addnode', ['127.0.0.1:$coreP2p', 'add']);
      await waitFor(
        'utreexod synced',
        () async => await utx.call('getblockcount') == 120,
        timeout: const Duration(seconds: 90),
      );
      expect(
        (await rpc.addNode(utxAddr, command: AddNodeCommand.add)).isRight(),
        isTrue,
      );
      await waitFor('validated 120', () async {
        final info = (await rpc.getBlockchainInfo()).toNullable();
        return info != null && info.validatedHeight == 120;
      }, timeout: const Duration(seconds: 90));
      // ignore: avoid_print
      print(
        'held ${DateTime.now().difference(heldSince).inSeconds}s with the '
        'peer; selection ended ${endedAfter.inSeconds}s after dropping it',
      );
    },
    skip: missing,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
