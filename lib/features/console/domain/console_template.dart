import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

/// What the RPC and Electrum consoles call into.
enum ConsoleKind { rpc, electrum }

/// Values the templates fill in, so they run as they are.
class ConsoleContext extends Equatable {
  const ConsoleContext({this.tipHeight, this.bestBlockHash});

  final int? tipHeight;
  final String? bestBlockHash;

  @override
  List<Object?> get props => [tipHeight, bestBlockHash];
}

/// A starting point in the console. Only methods that exist in florestad
/// v0.9.1 are listed (RPC: `json_rpc/server.rs` `handle_json_rpc_request`;
/// Electrum: `floresta-electrum/src/electrum_protocol.rs`).
class ConsoleTemplate {
  const ConsoleTemplate(
    this.method,
    this.description,
    this.category, {
    this.params = _none,
  });

  final String method;
  final String description;

  /// RPC console tab ("Blockchain", "Network", …); unused for Electrum.
  final String category;
  final List<Object?> Function(ConsoleContext) params;

  static List<Object?> _none(ConsoleContext _) => const [];
}

const rpcCategories = ['Blockchain', 'Network', 'Wallet', 'RawTX', 'Util'];

/// v0.9.1 RPC methods, read-only ones only. The rest of the methods
/// (`stop`, `addnode`, …) can still be typed in, behind a confirmation.
final rpcTemplates = <ConsoleTemplate>[
  const ConsoleTemplate(
    'getblockchaininfo',
    'Chain status and heights',
    'Blockchain',
  ),
  const ConsoleTemplate(
    'getbestblockhash',
    'Hash of the best header',
    'Blockchain',
  ),
  const ConsoleTemplate(
    'getblockcount',
    'Height of the best header',
    'Blockchain',
  ),
  ConsoleTemplate(
    'getblockhash',
    'Hash of the block at a height',
    'Blockchain',
    params: (c) => [c.tipHeight ?? 0],
  ),
  ConsoleTemplate(
    'getblockheader',
    'Header of a block',
    'Blockchain',
    params: (c) => [c.bestBlockHash ?? '<block hash>'],
  ),
  const ConsoleTemplate('getroots', 'Utreexo accumulator roots', 'Blockchain'),
  const ConsoleTemplate('getpeerinfo', 'Peer details', 'Network'),
  const ConsoleTemplate('ping', 'Ping every connected peer', 'Network'),
  const ConsoleTemplate(
    'listdescriptors',
    'Descriptors this node watches',
    'Wallet',
  ),
  const ConsoleTemplate(
    'getrawtransaction',
    'A transaction the wallet cache knows',
    'RawTX',
    params: _txid,
  ),
  const ConsoleTemplate(
    'gettxoutproof',
    'Merkle proof for a transaction',
    'RawTX',
    params: _txidList,
  ),
  const ConsoleTemplate('uptime', 'Seconds since the node started', 'Util'),
  const ConsoleTemplate('getmemoryinfo', 'Node memory use', 'Util'),
  const ConsoleTemplate('getrpcinfo', 'Active RPC commands', 'Util'),
];

List<Object?> _txid(ConsoleContext _) => const ['<txid>'];
List<Object?> _txidList(ConsoleContext _) => const [
  ['<txid>'],
];

/// v0.9.1 Electrum methods, read-only ones only.
final electrumTemplates = <ConsoleTemplate>[
  const ConsoleTemplate(
    'server.version',
    'Server software and protocol',
    '',
    params: _version,
  ),
  const ConsoleTemplate('server.features', 'Server capabilities', ''),
  const ConsoleTemplate('server.banner', 'Server banner', ''),
  const ConsoleTemplate('server.ping', 'Check the connection', ''),
  const ConsoleTemplate(
    'blockchain.headers.subscribe',
    'Current tip header',
    '',
  ),
  ConsoleTemplate(
    'blockchain.block.header',
    'Header at a height',
    '',
    params: (c) => [c.tipHeight ?? 0],
  ),
  const ConsoleTemplate(
    'blockchain.estimatefee',
    'Fee estimate for 6 blocks',
    '',
    params: _six,
  ),
  const ConsoleTemplate('blockchain.relayfee', 'Minimum relay fee', ''),
  const ConsoleTemplate(
    'blockchain.scripthash.get_balance',
    'Balance of a watched script',
    '',
    params: _scripthash,
  ),
  const ConsoleTemplate(
    'blockchain.scripthash.get_history',
    'History of a watched script',
    '',
    params: _scripthash,
  ),
  const ConsoleTemplate(
    'blockchain.transaction.get',
    'A transaction the wallet cache knows',
    '',
    params: _txid,
  ),
];

List<Object?> _version(ConsoleContext _) => const ['Floresta Desktop', '1.4'];
List<Object?> _six(ConsoleContext _) => const [6];
List<Object?> _scripthash(ConsoleContext _) => const ['<scripthash>'];

/// Methods that change the node or the network, which the console asks
/// about before running (v0.9.1).
const stateChangingMethods = {
  ConsoleKind.rpc: {
    'stop',
    'addnode',
    'disconnectnode',
    'loaddescriptor',
    'rescanblockchain',
    'sendrawtransaction',
  },
  ConsoleKind.electrum: {'blockchain.transaction.broadcast', 'server.add_peer'},
};

bool changesState(ConsoleKind kind, String method) =>
    stateChangingMethods[kind]!.contains(method.trim());

/// Params as florestad reads them: a JSON array of positional values
/// (v0.9.1 `RpcRequest.params: Vec<Value>`). Empty text and `{}` mean none.
Either<String, List<Object?>> parseParams(String text) {
  final t = text.trim();
  if (t.isEmpty) return const Right([]);
  final Object? decoded;
  try {
    decoded = jsonDecode(t);
  } on FormatException catch (e) {
    return Left('Params are not valid JSON: ${e.message}.');
  }
  return switch (decoded) {
    final List<Object?> list => Right(list),
    final Map<String, Object?> map when map.isEmpty => const Right([]),
    _ => const Left(
      'Params must be a JSON array of positional values, for example [] or '
      '[0]. Floresta does not take named parameters.',
    ),
  };
}

/// Pretty JSON for the response panel.
String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);
