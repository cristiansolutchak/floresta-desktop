import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../node/presentation/node_controller.dart';
import '../data/wallet_repository_impl.dart';
import '../domain/descriptor_input.dart';
import '../domain/wallet_repository.dart';

final walletRepositoryProvider = Provider<WalletRepository>(
  (ref) => WalletRepositoryImpl(ref.watch(rpcClientProvider)),
);

/// Watched descriptors as reported by the node. Left(failure) is a normal
/// state (node stopped), so it is data, not an AsyncError.
final walletDescriptorsProvider =
    AsyncNotifierProvider<WalletController, Either<Failure, List<String>>>(
      WalletController.new,
    );

class WalletController extends AsyncNotifier<Either<Failure, List<String>>> {
  WalletRepository get _repo => ref.read(walletRepositoryProvider);

  @override
  Future<Either<Failure, List<String>>> build() =>
      ref.watch(walletRepositoryProvider).listDescriptors();

  Future<void> reload() async {
    state = AsyncData(await _repo.listDescriptors());
  }

  Future<Either<Failure, Unit>> importDescriptor(String raw) async {
    final parsed = DescriptorInput.parse(raw);
    final result = await parsed.match(
      (failure) async => Left<Failure, Unit>(failure),
      _repo.loadDescriptor,
    );
    if (result.isRight()) await reload();
    return result;
  }

  Future<Either<Failure, Unit>> rescan({int? fromHeight}) =>
      _repo.rescan(fromHeight: fromHeight);
}
