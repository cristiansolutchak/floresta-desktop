import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/providers.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/wallet_label_store.dart';
import '../data/wallet_repository_impl.dart';
import '../data/watched_accounts.dart';
import '../domain/descriptor_input.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_labels.dart';
import '../domain/wallet_repository.dart';
import '../domain/watched_list.dart';
import 'wallet_sync_controller.dart';

final walletRepositoryProvider = Provider<WalletRepository>(
  (ref) => WalletRepositoryImpl(ref.watch(rpcClientProvider)),
);

/// Watched descriptors as reported by the node. Left(failure) is a normal
/// state (node stopped), so it is data, not an AsyncError.
final walletDescriptorsProvider =
    AsyncNotifierProvider<WalletController, Either<Failure, WatchedList>>(
      WalletController.new,
    );

class WalletController extends AsyncNotifier<Either<Failure, WatchedList>> {
  WalletRepository get _repo => ref.read(walletRepositoryProvider);

  /// Pause before asking again after an empty answer (WAL-07).
  static const recheckAfter = Duration(seconds: 3);
  Timer? _recheck;

  @override
  Future<Either<Failure, WatchedList>> build() async {
    ref.onDispose(() => _recheck?.cancel());
    final listed = await ref.watch(walletRepositoryProvider).listDescriptors();
    return _apply(const WatchedList([]), listed);
  }

  Either<Failure, WatchedList> _apply(
    WatchedList previous,
    Either<Failure, List<String>> listed,
  ) {
    final result = listed.map(previous.next);
    _recheck?.cancel();
    if (result.toNullable()?.checking ?? false) {
      _recheck = Timer(recheckAfter, reload);
    }
    return result;
  }

  Future<void> reload() async {
    final previous = state.value?.toNullable() ?? const WatchedList([]);
    final listed = await _repo.listDescriptors();
    if (!ref.mounted) return;
    state = AsyncData(_apply(previous, listed));
  }

  /// Imports an account: both branches, each once (florestad v0.9.1 keeps
  /// only the receive branch of a multipath import, and stores duplicates),
  /// named [name]. Rejects private key material, in the descriptor and the
  /// name, before anything reaches the node. Importing a wallet that was
  /// removed from this app brings it back.
  Future<Either<Failure, Unit>> importDescriptor(
    String raw, {
    required String name,
  }) async {
    final validName = WalletName.parse(name);
    if (validName case Left(:final value)) return Left(value);
    final checked = DescriptorInput.parse(raw);
    if (checked case Left(:final value)) return Left(value);
    final network = ref.read(settingsControllerProvider).network;
    final parsed = ref
        .read(descriptorParserProvider)
        .parseAccount(raw, network);
    if (parsed case Left(:final value)) return Left(value);
    final pair = parsed.getOrElse((_) => throw StateError('unreachable'));
    final registered = await ref
        .read(watchRegistrarProvider)
        .ensureWatched(
          WalletAccount(
            id: 'import',
            network: network,
            external: pair.external,
            internal: pair.internal,
          ),
        );
    if (registered case Left(:final value)) return Left(value);
    await ref
        .read(walletLabelsProvider.notifier)
        .named(
          WatchedAccounts.accountIdFor(pair.external),
          validName.getOrElse((_) => name),
        );
    await reload();
    return const Right(unit);
  }

  Future<Either<Failure, Unit>> rescan({int? fromHeight}) =>
      _repo.rescan(fromHeight: fromHeight);
}

/// Wallet names and removals (app-side; florestad has neither).
final walletLabelsProvider =
    NotifierProvider<WalletLabelsController, Map<String, WalletLabel>>(
      WalletLabelsController.new,
    );

class WalletLabelsController extends Notifier<Map<String, WalletLabel>> {
  WalletLabelStore get _store =>
      WalletLabelStore(ref.read(sharedPreferencesProvider));

  @override
  Map<String, WalletLabel> build() =>
      WalletLabelStore(ref.watch(sharedPreferencesProvider)).read();

  Future<void> _set(String id, WalletLabel label) async {
    state = {...state, id: label};
    await _store.write(state);
  }

  WalletLabel _of(String id) => state[id] ?? const WalletLabel();

  /// Names [id] and shows it again (an import, also of a removed wallet).
  Future<void> named(String id, String name) =>
      _set(id, WalletLabel(name: name));

  /// Renames [id]; the name is checked like an import's.
  Future<Either<Failure, Unit>> rename(String id, String raw) async {
    final name = WalletName.parse(raw);
    if (name case Left(:final value)) return Left(value);
    await _set(id, _of(id).copyWith(name: name.toOption()));
    return const Right(unit);
  }

  /// Removes [id] from this app (florestad keeps watching it).
  Future<void> remove(String id) => _set(id, _of(id).copyWith(hidden: true));

  /// Shows a removed wallet again.
  Future<void> restore(String id) => _set(id, _of(id).copyWith(hidden: false));
}
