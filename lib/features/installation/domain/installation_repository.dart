import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'installation.dart';

abstract interface class InstallationRepository {
  /// Finds and probes florestad.
  ///
  /// When [configuredPath] is set it is the only candidate: silently falling
  /// back to another binary would run something the user did not choose.
  /// Otherwise PATH and well-known locations are searched in order.
  ///
  /// Fails with `ExecutableNotFoundFailure` or `ExecutableInvalidFailure`.
  Future<Either<Failure, FlorestaInstallation>> detect({
    String? configuredPath,
  });
}
