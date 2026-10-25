import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/electrum/electrum_client.dart';
import '../../../core/electrum/electrum_transport.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../node/domain/node_status.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/bip32_address_deriver.dart';
import '../data/floresta_watch_registrar.dart';
import '../data/json_file_wallet_store.dart';
import '../data/node_chain_view.dart';
import '../data/script_address.dart';
import '../data/single_sig_descriptor_parser.dart';
import '../data/wallet_sync_engine.dart';
import '../data/watched_accounts.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_state.dart';
import '../domain/wallet_sync_ports.dart';
import 'wallet_controller.dart';

final descriptorParserProvider = Provider<DescriptorParser>(
  (ref) => const SingleSigDescriptorParser(),
);

final watchRegistrarProvider = Provider<FlorestaWatchRegistrar>(
  (ref) => FlorestaWatchRegistrar(ref.watch(walletRepositoryProvider)),
);

/// Address text for a scriptPubKey on a network (null if non-standard).
final addressEncoderProvider =
    Provider<String? Function(String scriptPubKey, BitcoinNetwork network)>(
      (ref) => addressForScript,
    );

final addressDeriverProvider = Provider<AddressDeriver>(
  (ref) => Bip32AddressDeriver(),
);

/// Builds the sync engine for one account: Floresta's own Electrum server
/// for history (claims) and its RPC for the chain (the authority), with the
/// account's public data stored under the app's data folder.
final walletEngineFactoryProvider =
    Provider<WalletSyncEngine Function(WalletAccount)>((ref) {
      final paths = ref.watch(appPathsProvider);
      final rpc = ref.watch(nodeRpcRepositoryProvider);
      final deriver = ref.watch(addressDeriverProvider);
      return (account) {
        final dir = paths.walletStore(account.network.cliValue)
          ..createSync(recursive: true);
        return WalletSyncEngine(
          account: account,
          client: TcpElectrumClient(
            ElectrumTransport(
              host: '127.0.0.1',
              port: account.network.electrumPort,
            ),
          ),
          chain: NodeChainView(rpc),
          store: JsonFileWalletStore(dir),
          deriver: deriver,
        );
      };
    });

/// Everything the Wallet screen shows (WAL-03).
class WalletOverview extends Equatable {
  const WalletOverview({
    this.watched = const WatchedAccounts(),
    this.snapshots = const {},
  });

  final WatchedAccounts watched;

  /// Latest snapshot per account id; missing until its engine reports.
  final Map<String, WalletSnapshot> snapshots;

  WalletSnapshot? snapshotOf(WalletAccount a) => snapshots[a.id];

  @override
  List<Object?> get props => [watched.accounts, snapshots];
}

/// Runs one [WalletSyncEngine] per complete account while the node's API is
/// up, and publishes their snapshots. Engines stop when the node goes down
/// or the watched set changes; their stored data stays.
class WalletSyncController extends Notifier<WalletOverview> {
  final _engines = <String, WalletSyncEngine>{};
  final _subs = <String, StreamSubscription<WalletSnapshot>>{};

  @override
  WalletOverview build() {
    ref.onDispose(_disposeAll);
    ref.listen(walletDescriptorsProvider, (_, _) => _reconcile());
    ref.listen(
      nodeControllerProvider.select((s) => s.api),
      (_, _) => _reconcile(),
    );
    // Electrum can announce a block before the node's RPC reports it as
    // validated; the engine then marks it "pending validation" and gets no
    // further notification. Re-sync whenever the validated height moves
    // (cheap: unchanged scripts are skipped). Seen on the regtest cluster.
    ref.listen(nodeControllerProvider.select((s) => s.chain?.validatedHeight), (
      prev,
      next,
    ) {
      if (prev != null && next != null && next > prev) {
        unawaited(refresh());
      }
    });
    // First reconciliation once `state` exists.
    Future.microtask(() {
      if (ref.mounted) _reconcile();
    });
    return const WalletOverview();
  }

  void _reconcile() {
    final apiUp =
        ref.read(nodeControllerProvider).api == ApiReachability.reachable;
    final listed = ref.read(walletDescriptorsProvider).value?.toNullable();
    final network = ref.read(settingsControllerProvider).network;
    final watched = listed == null
        ? const WatchedAccounts()
        : WatchedAccounts.fromListed(
            listed.descriptors,
            network,
            parser: ref.read(descriptorParserProvider),
          );
    final wanted = apiUp
        ? {for (final a in watched.accounts) a.id: a}
        : const <String, WalletAccount>{};

    for (final id in _engines.keys.toList()) {
      if (!wanted.containsKey(id)) unawaited(_stop(id));
    }
    final factory = ref.read(walletEngineFactoryProvider);
    for (final MapEntry(key: id, value: account) in wanted.entries) {
      if (_engines.containsKey(id)) continue;
      final engine = factory(account);
      _engines[id] = engine;
      _subs[id] = engine.snapshots.listen((snap) {
        if (!ref.mounted) return;
        state = WalletOverview(
          watched: state.watched,
          snapshots: {...state.snapshots, id: snap},
        );
      });
      unawaited(engine.start());
    }
    state = WalletOverview(
      watched: watched,
      snapshots: {
        for (final e in state.snapshots.entries)
          if (wanted.containsKey(e.key) || !apiUp) e.key: e.value,
      },
    );
  }

  /// Runs a sync pass now on every account (the Refresh button).
  Future<void> refresh() async {
    await Future.wait([for (final e in _engines.values) e.syncOnce()]);
  }

  Future<void> _stop(String id) async {
    await _subs.remove(id)?.cancel();
    await _engines.remove(id)?.dispose();
  }

  void _disposeAll() {
    for (final id in _engines.keys.toList()) {
      unawaited(_stop(id));
    }
  }
}

final walletSyncProvider =
    NotifierProvider<WalletSyncController, WalletOverview>(
      WalletSyncController.new,
    );
