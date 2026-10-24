import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'descriptor_input.dart';

/// Floresta's watch-only wallet, as exposed over JSON-RPC.
///
/// Upstream has no balance, history or spending RPCs
/// (docs/research/floresta-capabilities.md §7); do not add methods here that
/// imply otherwise.
abstract interface class WalletRepository {
  Future<Either<Failure, List<String>>> listDescriptors();

  /// `loaddescriptor`. Floresta derives 100 addresses per keychain and
  /// starts a background rescan; it reports no progress.
  Future<Either<Failure, Unit>> loadDescriptor(DescriptorInput descriptor);

  /// `rescanblockchain [startHeight]`. Returns once the rescan is *started*.
  Future<Either<Failure, Unit>> rescan({int? fromHeight});
}
