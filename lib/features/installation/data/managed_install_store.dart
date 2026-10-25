import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/security/file_hash.dart';
import '../domain/installation.dart';

/// Reads and atomically replaces `current.json`, the record of the
/// app-managed florestad.
class ManagedInstallStore {
  ManagedInstallStore(this.paths);

  final AppPaths paths;

  /// Right(null) when nothing was ever installed by the app.
  Future<Either<Failure, ManagedInstall?>> read() async {
    final file = paths.currentPointer;
    if (!await file.exists()) return const Right(null);
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return Right(ManagedInstall.fromJson(json));
    } on Object catch (e) {
      return Left(
        InstallationFailure(
          stage: 'recover',
          message: 'The record of the installed Floresta is unreadable ($e).',
          recovery: 'Reinstall Floresta from Installation.',
        ),
      );
    }
  }

  Future<void> write(ManagedInstall install) async {
    final file = paths.currentPointer;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(install.toJson()), flush: true);
    await temp.rename(file.path);
  }

  /// True when the recorded binary exists and still has the recorded hash.
  Future<bool> isIntact(ManagedInstall install) async {
    final file = File(install.path);
    if (!await file.exists()) return false;
    return await sha256OfFile(install.path) == install.sha256;
  }
}
