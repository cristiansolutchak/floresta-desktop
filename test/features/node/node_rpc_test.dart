import 'dart:convert';

import 'package:floresta_gui/core/errors/failure.dart';
import 'package:floresta_gui/core/rpc/json_rpc_client.dart';
import 'package:floresta_gui/features/node/data/node_rpc_repository_impl.dart';
import 'package:floresta_gui/features/node/data/rpc_models.dart';
import 'package:floresta_gui/features/node/domain/blockchain_info.dart';
import 'package:floresta_gui/features/node/domain/node_process_state.dart';
import 'package:floresta_gui/features/node/domain/node_status.dart';
import 'package:floresta_gui/features/node/presentation/status_labels.dart';
import 'package:floresta_gui/features/settings/domain/bitcoin_network.dart';
import 'package:floresta_gui/shared/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Shape of `getblockchaininfo` as built in
/// crates/floresta-node/src/json_rpc/blockchain.rs (corepc v30 field names).
Map<String, Object?> blockchainInfoJson({
  String chain = 'signet',
  int blocks = 200000,
  int headers = 200000,
  bool ibd = false,
  double progress = 1.0,
}) => {
  'chain': chain,
  'blocks': blocks,
  'headers': headers,
  'bestblockhash':
      '00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6',
  'bits': '1e0377ae',
  'target': '00000377ae000000000000000000000000000000000000000000000000000000',
  'difficulty': 0.001,
  'time': 1700000000,
  'mediantime': 1699999000,
  'verificationprogress': progress,
  'initialblockdownload': ibd,
  'chainwork':
      '0000000000000000000000000000000000000000000000000000000000000001',
  'size_on_disk': 52428800,
  'pruned': true,
  'pruneheight': blocks + 1,
  'automatic_pruning': true,
  'prune_target_size': 0,
  'signet_challenge': null,
  'warnings': <String>[],
};

/// Shape of Floresta's `PeerInfo` (crates/floresta-rpc/src/rpc_types.rs).
const peerJson = {
  'id': 3,
  'address': '1.2.3.4:38333',
  'services': '0000000001000009',
  'servicesnames': ['NETWORK', 'WITNESS', 'UTREEXO'],
  'relaytxes': false,
  'user_agent': '/Floresta:0.9.1/',
  'inbound': false,
  'bip152_hb_to': false,
  'bip152_hb_from': false,
  'initial_height': 199990,
  'timeoffset': 0,
  'kind': 'Regular',
  'state': 'Ready',
  'permissions': <String>[],
  'transport_protocol': 'V2',
};

void main() {
  group('RpcModels', () {
    test('maps getblockchaininfo', () {
      final info = RpcModels.blockchainInfo(blockchainInfoJson());
      expect(info.network, BitcoinNetwork.signet);
      expect(info.validatedHeight, 200000);
      expect(info.phase, SyncPhase.synced);
      expect(info.sizeOnDisk, 52428800);
      expect(info.tipTime.isUtc, isTrue);
    });

    test('accepts both "main" (code) and "bitcoin" (docs) for mainnet', () {
      expect(
        RpcModels.blockchainInfo(blockchainInfoJson(chain: 'main')).network,
        BitcoinNetwork.bitcoin,
      );
      expect(
        RpcModels.blockchainInfo(blockchainInfoJson(chain: 'bitcoin')).network,
        BitcoinNetwork.bitcoin,
      );
    });

    test('keeps unknown chains without failing', () {
      final info = RpcModels.blockchainInfo(blockchainInfoJson(chain: 'test'));
      expect(info.network, isNull);
      expect(info.chain, 'test');
    });

    test('accepts legacy string warnings', () {
      final json = blockchainInfoJson()..['warnings'] = 'clock skew';
      expect(RpcModels.blockchainInfo(json).warnings, ['clock skew']);
    });

    test('maps getpeerinfo', () {
      final peer = RpcModels.peers([peerJson]).single;
      expect(peer.address, '1.2.3.4:38333');
      expect(peer.isReady, isTrue);
      expect(peer.supportsUtreexo, isTrue);
      expect(peer.transport, 'V2');
    });

    test('throws TypeError on wrong shapes', () {
      expect(
        () => RpcModels.blockchainInfo({'chain': 1}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('BlockchainInfo.phase', () {
    test('distinguishes IBD, catching up and synced', () {
      SyncPhase phase(Map<String, Object?> j) =>
          RpcModels.blockchainInfo(j).phase;
      expect(
        phase(blockchainInfoJson(ibd: true, blocks: 10)),
        SyncPhase.initialDownload,
      );
      expect(phase(blockchainInfoJson(blocks: 199990)), SyncPhase.catchingUp);
      expect(phase(blockchainInfoJson()), SyncPhase.synced);
    });
  });

  group('NodeRpcRepositoryImpl', () {
    NodeRpcRepositoryImpl repo(Object? Function(String method) result) =>
        NodeRpcRepositoryImpl(
          JsonRpcClient(
            endpoint: Uri.parse('http://127.0.0.1:38332/'),
            httpClient: MockClient((req) async {
              final body = jsonDecode(req.body) as Map<String, Object?>;
              return http.Response(
                jsonEncode({
                  'id': body['id'],
                  'result': result(body['method']! as String),
                }),
                200,
              );
            }),
          ),
        );

    test('reads chain, peers and uptime', () async {
      final r = repo(
        (m) => switch (m) {
          'getblockchaininfo' => blockchainInfoJson(),
          'getpeerinfo' => [peerJson],
          'uptime' => 3600,
          _ => null,
        },
      );
      expect((await r.getBlockchainInfo()).isRight(), isTrue);
      expect((await r.getPeers()).toNullable(), hasLength(1));
      expect((await r.getUptime()).toNullable(), const Duration(hours: 1));
      expect((await r.requestStop()).isRight(), isTrue);
    });

    test('reports a malformed failure for unexpected shapes', () async {
      final r = repo((_) => 'unexpected');
      expect(
        (await r.getBlockchainInfo()).getLeft().toNullable(),
        isA<RpcMalformedResponseFailure>(),
      );
    });
  });

  group('StatusLabels', () {
    test('a running process with no API is "waiting", not an error', () {
      final s = NodeStatus(
        process: ProcessRunning(1, DateTime(2026)),
        api: ApiReachability.unreachable,
      );
      expect(StatusLabels.process(s).label, 'Running');
      expect(StatusLabels.api(s).label, 'Waiting for the node');
      expect(StatusLabels.api(s).tone, Tone.warning);
      expect(StatusLabels.sync(s).label, 'Unknown');
    });

    test('a reachable API without a supervised process is external', () {
      const s = NodeStatus(api: ApiReachability.reachable);
      expect(s.isExternallyManaged, isTrue);
      expect(s.canStart, isFalse);
      expect(s.canStop, isTrue);
      expect(StatusLabels.process(s).label, 'Started outside this app');
    });

    test('sync wording marks progress as an estimate', () {
      final s = NodeStatus(
        api: ApiReachability.reachable,
        chain: RpcModels.blockchainInfo(
          blockchainInfoJson(ibd: true, progress: 0.4213),
        ),
      );
      expect(StatusLabels.sync(s).label, 'Initial sync');
      expect(StatusLabels.sync(s).caption, '42.13% (estimate)');
    });

    test('crashes are shown as errors', () {
      const s = NodeStatus(process: ProcessCrashed(1, []));
      expect(StatusLabels.process(s).tone, Tone.danger);
    });
  });

  group('formatters', () {
    test('format integers, bytes and durations', () {
      expect(formatInt(1234567), '1,234,567');
      expect(formatInt(999), '999');
      expect(formatBytes(52428800), '52.4 MB');
      expect(formatDuration(const Duration(hours: 26)), '1d 2h');
      expect(formatDuration(const Duration(seconds: 42)), '42s');
    });
  });
}
