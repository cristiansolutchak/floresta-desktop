import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/wallet_repository_impl.dart';
import '../domain/descriptor_input.dart';
import '../domain/wallet_account.dart';
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
  /// only the receive branch of a multipath import, and stores duplicates).
  /// Rejects private key material before anything reaches the node.
  Future<Either<Failure, Unit>> importDescriptor(String raw) async {
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
    await reload();
    return const Right(unit);
  }

  Future<Either<Failure, Unit>> rescan({int? fromHeight}) =>
      _repo.rescan(fromHeight: fromHeight);
}
