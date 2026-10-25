import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../domain/installation.dart';
import '../domain/installation_repository.dart';
import 'executable_locator.dart';
import 'managed_install_store.dart';
import 'version_probe.dart';

/// Detection order: an explicitly configured path, then the app-managed
/// install (`current.json`), then PATH and well-known locations.
class InstallationRepositoryImpl implements InstallationRepository {
  InstallationRepositoryImpl({
    required this.locator,
    required this.probe,
    this.managed,
  });

  final ExecutableLocator locator;
  final VersionProbe probe;
  final ManagedInstallStore? managed;

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
    } else if (await _managedCandidate() case final managedResult?) {
      if (managedResult case Left(:final value)) return Left(value);
      candidate = managedResult.getOrElse((_) => throw StateError(''));
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

  /// Null when there is no managed install. A damaged one is an error rather
  /// than a silent fallback to some other florestad on the system.
  Future<Either<Failure, ExecutableCandidate>?> _managedCandidate() async {
    final store = managed;
    if (store == null) return null;
    final record = await store.read();
    if (record case Left(:final value)) return Left(value);
    final install = record.getOrElse((_) => null);
    if (install == null) return null;
    if (!await store.isIntact(install)) {
      return Left(
        ExecutableInvalidFailure(
          install.path,
          'The Floresta installed by this app is missing or was modified.',
          recovery: 'Reinstall Floresta from Installation.',
        ),
      );
    }
    return Right(ExecutableCandidate(install.path, ExecutableSource.managed));
  }
}
