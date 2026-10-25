import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../domain/descriptor_input.dart';
import '../domain/wallet_account.dart';
import '../domain/wallet_repository.dart';

/// Makes florestad watch exactly an account's two single-branch descriptors.
///
/// florestad v0.9.1 stores duplicate imports twice and keeps only the
/// external branch of a multipath import, so each branch is imported once,
/// separately, after checking `listdescriptors`.
class FlorestaWatchRegistrar {
  FlorestaWatchRegistrar(this._wallet);

  final WalletRepository _wallet;

  /// Returns how many descriptors were newly imported (0, 1 or 2).
  Future<Either<Failure, int>> ensureWatched(WalletAccount account) async {
    final listed = await _wallet.listDescriptors();
    if (listed case Left(:final value)) return Left(value);
    final existing = listed.getOrElse((_) => const []).toSet();
    var imported = 0;
    for (final d in [account.external, account.internal]) {
      if (existing.contains(d.value)) continue;
      final input = DescriptorInput.parse(d.value);
      if (input case Left(:final value)) return Left(value);
      final loaded = await _wallet.loadDescriptor(
        input.getOrElse((_) => throw StateError('')),
      );
      if (loaded case Left(:final value)) return Left(value);
      imported++;
    }
    return Right(imported);
  }
}
