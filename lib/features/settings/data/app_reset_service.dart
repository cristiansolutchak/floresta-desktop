import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/app_paths.dart';
import '../domain/app_reset.dart';

/// INS-12: carries out the three [ResetScope]s. Each removes only what it
/// names; callers must stop the node first and confirm with the user.
class AppResetService {
  AppResetService({required this.prefs, required this.paths});

  final SharedPreferences prefs;
  final AppPaths paths;

  /// Prefixes of every preference this app writes.
  static const _ownedPrefixes = ['settings.', 'wallet.'];

  /// Clears this app's preferences. The next launch starts the wizard.
  Future<Either<Failure, Unit>> resetSettings() async {
    try {
      for (final k in prefs.getKeys().toList()) {
        if (_ownedPrefixes.any(k.startsWith)) await prefs.remove(k);
      }
      return const Right(unit);
    } on Object catch (e) {
      return Left(ResetFailure('Could not clear the app settings ($e).'));
    }
  }

  /// The florestad copies this app installed (`versions/`, `.staging/`,
  /// `current.json`). Keeps `trust.json`, so a reinstall still refuses
  /// release information older than what this computer already saw.
  List<FileSystemEntity> get managedFloresta => [
    paths.versions,
    paths.staging,
    paths.currentPointer,
  ].where((e) => e.existsSync()).toList();

  Future<Either<Failure, Unit>> removeManagedFloresta() async {
    try {
      for (final e in managedFloresta) {
        await e.delete(recursive: true);
      }
      return const Right(unit);
    } on Object catch (e) {
      return Left(
        ResetFailure(
          'Could not remove the installed Floresta ($e).',
          recovery: 'Stop the node, then try again.',
        ),
      );
    }
  }

  /// What [deleteChainData] would remove from [dataDir], or a failure when
  /// the folder is missing or is not recognisably Floresta's.
  Either<Failure, List<String>> chainDataIn(String dataDir) {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) {
      return const Left(ResetFailure('There is no node data in this folder.'));
    }
    final names = {
      for (final e in dir.listSync(followLinks: false))
        e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    };
    if (!looksLikeFlorestaData(names)) {
      return Left(
        ResetFailure(
          '$dataDir does not look like a Floresta data folder, so nothing '
          'in it is removed.',
        ),
      );
    }
    return Right(chainDataToDelete(names));
  }

  /// Deletes only the [florestadDataEntries] and Sled snapshots in
  /// [dataDir] ([chainDataToDelete]); the folder and
  /// anything else in it (other networks' folders, user files) stay.
  Future<Either<Failure, List<String>>> deleteChainData(String dataDir) async {
    final plan = chainDataIn(dataDir);
    if (plan case Left(:final value)) return Left(value);
    final names = plan.getOrElse((_) => const []);
    try {
      for (final n in names) {
        final path = '$dataDir${Platform.pathSeparator}$n';
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        // Never follow a link out of the data folder.
        if (type == FileSystemEntityType.link) {
          await Link(path).delete();
        } else if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(path).delete();
        }
      }
      return Right(names);
    } on Object catch (e) {
      return Left(
        ResetFailure(
          'Removing the node data stopped part way ($e).',
          recovery:
              'Stop the node and try again. Floresta rebuilds anything that '
              'is missing on its next start.',
        ),
      );
    }
  }
}
