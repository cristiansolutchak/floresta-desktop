import 'package:floresta_gui/features/console/domain/console_template.dart';
import 'package:flutter_test/flutter_test.dart';

/// Method names in florestad v0.9.1 (`crates/floresta-node/src/json_rpc/
/// server.rs` `handle_json_rpc_request`, tag v0.9.1, checked 2026-10-25).
const _v091Rpc = {
  'addnode',
  'disconnectnode',
  'findtxout',
  'getbestblockhash',
  'getblock',
  'getblockchaininfo',
  'getblockcount',
  'getblockfrompeer',
  'getblockhash',
  'getblockheader',
  'getmemoryinfo',
  'getpeerinfo',
  'getrawtransaction',
  'getroots',
  'getrpcinfo',
  'gettxout',
  'gettxoutproof',
  'listdescriptors',
  'loaddescriptor',
  'ping',
  'rescanblockchain',
  'sendrawtransaction',
  'stop',
  'uptime',
};

/// `crates/floresta-electrum/src/electrum_protocol.rs`, tag v0.9.1.
const _v091Electrum = {
  'blockchain.block.header',
  'blockchain.block.headers',
  'blockchain.estimatefee',
  'blockchain.headers.subscribe',
  'blockchain.relayfee',
  'blockchain.scripthash.get_balance',
  'blockchain.scripthash.get_history',
  'blockchain.scripthash.get_mempool',
  'blockchain.scripthash.listunspent',
  'blockchain.scripthash.subscribe',
  'blockchain.scripthash.unsubscribe',
  'blockchain.transaction.broadcast',
  'blockchain.transaction.get',
  'blockchain.transaction.get_merkle',
  'mempool.get_fee_histogram',
  'server.add_peer',
  'server.banner',
  'server.donation_address',
  'server.features',
  'server.peers.subscribe',
  'server.ping',
  'server.version',
};

void main() {
  test('templates only use methods that exist in v0.9.1', () {
    expect(
      rpcTemplates.map((t) => t.method).toSet(),
      everyElement(isIn(_v091Rpc)),
    );
    expect(
      electrumTemplates.map((t) => t.method).toSet(),
      everyElement(isIn(_v091Electrum)),
    );
    // getnetworkinfo and help do not exist in florestad v0.9.1.
    expect(
      rpcTemplates.map((t) => t.method),
      isNot(contains('getnetworkinfo')),
    );
    expect(rpcTemplates.map((t) => t.method), isNot(contains('help')));
  });

  test('every RPC tab has a template, and none of them changes state', () {
    for (final c in rpcCategories) {
      expect(rpcTemplates.where((t) => t.category == c), isNotEmpty, reason: c);
    }
    for (final t in rpcTemplates) {
      expect(
        changesState(ConsoleKind.rpc, t.method),
        isFalse,
        reason: t.method,
      );
    }
    for (final t in electrumTemplates) {
      expect(
        changesState(ConsoleKind.electrum, t.method),
        isFalse,
        reason: t.method,
      );
    }
  });

  test('state-changing methods are flagged', () {
    for (final m in [
      'stop',
      'addnode',
      'loaddescriptor',
      ' sendrawtransaction ',
    ]) {
      expect(changesState(ConsoleKind.rpc, m), isTrue, reason: m);
    }
    expect(
      changesState(ConsoleKind.electrum, 'blockchain.transaction.broadcast'),
      isTrue,
    );
  });

  test('templates fill in the current tip', () {
    final tpl = rpcTemplates.firstWhere((t) => t.method == 'getblockhash');
    expect(tpl.params(const ConsoleContext(tipHeight: 940729)), [940729]);
  });

  group('parseParams', () {
    test('empty, [] and {} mean no params', () {
      expect(parseParams('').getOrElse((_) => [1]), isEmpty);
      expect(parseParams(' [] ').getOrElse((_) => [1]), isEmpty);
      expect(parseParams('{}').getOrElse((_) => [1]), isEmpty);
    });

    test('arrays are positional params', () {
      expect(parseParams('[0, "add", true]').getOrElse((_) => []), [
        0,
        'add',
        true,
      ]);
    });

    test('named params and bad JSON are refused with a reason', () {
      expect(parseParams('{"height": 1}').isLeft(), isTrue);
      expect(parseParams('[0,').isLeft(), isTrue);
    });
  });
}
