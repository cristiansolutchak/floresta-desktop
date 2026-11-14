import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:floresta_desktop/core/rpc/json_rpc_client.dart';
import 'package:floresta_desktop/features/node/data/florestad_process_manager.dart';
import 'package:floresta_desktop/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_desktop/features/node/domain/node_process_state.dart';
import 'package:floresta_desktop/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_desktop/features/settings/domain/node_settings.dart';
import 'package:http/http.dart' as http;

/// Test-only regtest cluster: bitcoind (miner + disposable test wallets) →
/// utreexod bridge → florestad (system under test).
///
/// Everything runs on loopback in a fresh temp directory. bitcoind is forced
/// to `-regtest` and its chain is checked before any test runs, so these
/// tests can never touch mainnet or real funds.
class RegtestCluster {
  RegtestCluster._(this.root);

  static String? get missingTools {
    final env = Platform.environment;
    final missing = [
      for (final k in ['FLORESTAD_PATH', 'UTREEXOD_PATH', 'BITCOIND_PATH'])
        if ((env[k] ?? '').isEmpty) k,
    ];
    return missing.isEmpty
        ? null
        : 'Set ${missing.join(', ')} (source the env file from '
              'tool/regtest/bootstrap.sh) to run wallet-sync integration tests';
  }

  final Directory root;
  Directory? _utreexodAppDir;
  bool _utreexodAppDirExisted = true;
  final _processes = <Process>[];

  static Directory? _utreexodAppDataDir() {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    if (Platform.isMacOS) {
      return Directory('$home/Library/Application Support/Utreexod');
    }
    if (Platform.isLinux) return Directory('$home/.utreexod');
    return null;
  }

  final logs = <String, IOSink>{};
  late final int corePort, coreP2p, utxRpc, utxP2p, floRpc, floElectrum;
  late final CoreRpc core;
  late final FlorestadProcessManager florestad;
  late final NodeRpcRepositoryImpl floRpcRepo;
  late final http.Client _http;
  late final NodeSettings floSettings;

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  /// Extra florestad flags for a test (e.g. `--filters-start-height`).
  List<String> florestadExtraArgs = const [];
  int? _fixedElectrumPort;

  /// [electrumPort] fixes florestad's Electrum port (e.g. regtest's default
  /// 20001, where the app looks for it); otherwise a free one is used.
  static Future<RegtestCluster> start({
    List<String> florestadExtraArgs = const [],
    int? electrumPort,
  }) async {
    final c =
        RegtestCluster._(
            await Directory.systemTemp.createTemp('floresta_cluster_'),
          )
          ..florestadExtraArgs = florestadExtraArgs
          .._fixedElectrumPort = electrumPort;
    try {
      await c._start();
    } catch (_) {
      await c.dispose();
      rethrow;
    }
    return c;
  }

  Future<void> _start() async {
    final env = Platform.environment;
    corePort = await _freePort();
    coreP2p = await _freePort();
    utxRpc = await _freePort();
    utxP2p = await _freePort();
    floRpc = await _freePort();
    floElectrum = _fixedElectrumPort ?? await _freePort();
    _http = http.Client();

    // --- bitcoind -----------------------------------------------------------
    final coreDir = Directory('${root.path}/bitcoind')..createSync();
    await _spawn('bitcoind', env['BITCOIND_PATH']!, [
      '-regtest',
      '-datadir=${coreDir.path}',
      '-port=$coreP2p',
      '-bind=127.0.0.1:$coreP2p',
      '-rpcport=$corePort',
      '-rpcbind=127.0.0.1',
      '-rpcallowip=127.0.0.1',
      '-rpcuser=test',
      '-rpcpassword=test',
      '-listen=1',
      '-dnsseed=0',
      '-fixedseeds=0',
      '-connect=0',
      '-v2transport=0',
      '-txindex=1',
      '-fallbackfee=0.0002',
      '-printtoconsole=1',
    ]);
    core = CoreRpc(_http, corePort);
    await waitFor(
      'bitcoind RPC',
      () async => (await core.call('getblockcount')) is int,
    );
    final chain = (await core.call('getblockchaininfo') as Map)['chain'];
    if (chain != 'regtest') {
      throw StateError('bitcoind is on "$chain", refusing to continue');
    }
    await core.call('createwallet', ['miner']);
    await core.call('createwallet', ['subject']);
    final minerAddr = await core.call('getnewaddress', [], 'miner') as String;
    await core.call('generatetoaddress', [110, minerAddr]);

    // --- utreexod bridge ------------------------------------------------------
    // utreexod always creates its app-data dir under the OS account's home
    // (btcutil.AppDataDir prefers user.Current() over $HOME; config.go:576).
    // Data, logs and config go to the temp dir; the empty app-data dir is
    // removed in dispose() only if this run created it.
    _utreexodAppDir = _utreexodAppDataDir();
    _utreexodAppDirExisted = _utreexodAppDir?.existsSync() ?? true;
    final conf = File('${root.path}/utreexod.conf')..writeAsStringSync('');
    await _spawn('utreexod', env['UTREEXOD_PATH']!, [
      '--configfile=${conf.path}',
      '--regtest',
      '--datadir=${root.path}/utreexod',
      '--logdir=${root.path}/utreexod',
      '--listen=127.0.0.1:$utxP2p',
      '--rpclisten=127.0.0.1:$utxRpc',
      '--notls',
      '--rpcuser=test',
      '--rpcpass=test',
      '--connect=127.0.0.1:$coreP2p',
      '--noutreexo',
      '--flatutreexoproofindex',
      '--prune=0',
      '--nodnsseed',
    ]);
    final utx = CoreRpc(_http, utxRpc, jsonrpc: '1.0');
    await waitFor(
      'utreexod at 110',
      () async => await utx.call('getblockcount') == 110,
    );

    // --- florestad (via the app's own process manager) ------------------------
    floSettings = NodeSettings(
      network: BitcoinNetwork.regtest,
      dataDir: '${root.path}/florestad',
      rpcPort: floRpc,
      logToFile: false,
    );
    floRpcRepo = NodeRpcRepositoryImpl(
      JsonRpcClient(endpoint: floSettings.rpcEndpoint, httpClient: _http),
    );
    florestad = FlorestadProcessManager(
      startProcess: (exe, args) => Process.start(exe, [
        ...args,
        '--electrum-address',
        '127.0.0.1:$floElectrum',
        '--connect',
        '127.0.0.1:$utxP2p',
        '--disable-dns-seeds',
        ...florestadExtraArgs,
      ]),
      requestGracefulStop: (_) async =>
          (await floRpcRepo.requestStop()).isRight(),
    );
    await startFlorestad();
  }

  Future<void> startFlorestad() async {
    final started = await florestad.start(
      executablePath: Platform.environment['FLORESTAD_PATH']!,
      settings: floSettings,
    );
    if (started.isLeft()) throw StateError('florestad: $started');
    await waitForFlorestaSynced();
  }

  Future<void> stopFlorestad() async {
    await florestad.stop();
    if (florestad.state is! ProcessStopped) {
      throw StateError('florestad did not stop cleanly: ${florestad.state}');
    }
  }

  /// Waits until florestad validated Core's tip and left IBD. Blocks must
  /// not be mined during florestad's IBD→running transition: v0.9.1 misses
  /// announcements made then.
  Future<void> waitForFlorestaSynced({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final target = await core.call('getblockcount') as int;
    final targetHash = await core.call('getbestblockhash') as String;
    await waitFor('florestad at $target', () async {
      final info = (await floRpcRepo.getBlockchainInfo()).toNullable();
      if (info == null ||
          info.validatedHeight != target ||
          info.initialBlockDownload) {
        return false;
      }
      return (await floRpcRepo.getBlockHash(target)).toNullable() == targetHash;
    }, timeout: timeout);
  }

  Future<List<String>> mine(int blocks, {String? to}) async {
    final address =
        to ?? await core.call('getnewaddress', [], 'miner') as String;
    final hashes =
        (await core.call('generatetoaddress', [blocks, address]) as List)
            .cast<String>();
    await waitForFlorestaSynced();
    return hashes;
  }

  Future<Process> _spawn(
    String name,
    String exe,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final p = await Process.start(exe, args, environment: environment);
    final sink = File('${root.path}/$name.log').openWrite();
    logs[name] = sink;
    p.stdout.listen(sink.add);
    p.stderr.listen(sink.add);
    _processes.add(p);
    return p;
  }

  String logTail(String name, [int lines = 40]) {
    final f = File('${root.path}/$name.log');
    if (!f.existsSync()) return '';
    final all = f.readAsLinesSync();
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  }

  Future<void> dispose() async {
    try {
      await florestad.dispose();
    } catch (_) {}
    try {
      await core.call('stop');
    } catch (_) {}
    for (final p in _processes.reversed) {
      p.kill(ProcessSignal.sigint);
    }
    for (final p in _processes) {
      try {
        await p.exitCode.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
      }
    }
    for (final s in logs.values) {
      await s.close();
    }
    try {
      _http.close();
    } catch (_) {}
    if (root.path.contains('floresta_cluster_') && root.existsSync()) {
      await root.delete(recursive: true);
    }
    final appDir = _utreexodAppDir;
    if (appDir != null && !_utreexodAppDirExisted && appDir.existsSync()) {
      // Never recursive: only an empty directory this run created is removed.
      if (appDir.listSync().isEmpty) await appDir.delete();
    }
  }
}

/// Minimal JSON-RPC client for bitcoind/utreexod (test-only, basic auth).
class CoreRpc {
  CoreRpc(this._http, this.port, {this.jsonrpc = '1.0'});
  final http.Client _http;
  final int port;
  final String jsonrpc;

  Future<Object?> call(
    String method, [
    List<Object?> params = const [],
    String? wallet,
  ]) async {
    final uri = Uri.parse(
      'http://127.0.0.1:$port/${wallet == null ? '' : 'wallet/$wallet'}',
    );
    final res = await _http
        .post(
          uri,
          headers: {
            'Authorization': 'Basic ${base64Encode(utf8.encode('test:test'))}',
          },
          body: jsonEncode({
            'jsonrpc': jsonrpc,
            'id': 1,
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 60));
    final body = jsonDecode(res.body) as Map<String, Object?>;
    if (body['error'] != null) throw StateError('$method: ${body['error']}');
    return body['result'];
  }
}

Future<void> waitFor(
  String what,
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 60),
  Duration interval = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      if (await check()) return;
    } catch (e) {
      lastError = e;
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    'Timed out waiting for $what (last error: $lastError)',
  );
}
