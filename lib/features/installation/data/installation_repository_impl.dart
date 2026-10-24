import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../domain/installation.dart';
import '../domain/installation_repository.dart';
import 'executable_locator.dart';
import 'version_probe.dart';

class InstallationRepositoryImpl implements InstallationRepository {
  InstallationRepositoryImpl({required this.locator, required this.probe});

  final ExecutableLocator locator;
  final VersionProbe probe;

  @override
  Future<Either<Failure, FlorestaInstallation>> detect({
    String? configuredPath,
  }) async {
    final ExecutableCandidate candidate;
    if (configuredPath != null) {
      if (!await locator.isUsable(configuredPath)) {
        return Left(
          ExecutableInvalidFailure(
            configuredPath,
            'The selected file does not exist or is not executable.',
            recovery:
                'Choose the florestad executable again, or switch to '
                'automatic detection.',
          ),
        );
      }
      candidate = ExecutableCandidate(
        configuredPath,
        ExecutableSource.configured,
      );
    } else {
      final found = await locator.find();
      if (found == null) {
        return Left(
          ExecutableNotFoundFailure([
            for (final c in locator.candidates()) c.path,
          ]),
        );
      }
      candidate = found;
    }

    final version = await probe.probe(candidate.path);
    return version.map(
      (v) => FlorestaInstallation(
        executablePath: candidate.path,
        source: candidate.source,
        version: v,
      ),
    );
  }
}
