import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/platform/app_paths.dart';

/// What this computer has already accepted from the release source.
typedef ReleaseTrust = ({int highestSerial, Set<String> revokedKeys});

/// Persists anti-rollback state in `trust.json`, replaced atomically.
class ReleaseTrustStore {
  ReleaseTrustStore(this.paths);

  final AppPaths paths;

  static const ReleaseTrust initial = (highestSerial: 0, revokedKeys: {});

  /// Fails closed: an unreadable record is an error, never "nothing seen",
  /// because that would re-open rollback.
  Future<Either<Failure, ReleaseTrust>> read() async {
    final file = paths.trustRecord;
    if (!await file.exists()) return const Right(initial);
    try {
      final m = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return Right((
        highestSerial: m['highestSerial']! as int,
        revokedKeys: {for (final k in m['revokedKeys']! as List) k as String},
      ));
    } on Object catch (e) {
      return Left(
        InstallationFailure(
          stage: 'verify',
          message: 'The record of trusted releases is unreadable ($e).',
          recovery:
              'Nothing was installed. Choose an existing florestad '
              'executable instead, or contact support.',
        ),
      );
    }
  }

  /// Records an accepted manifest. Never lowers the serial or un-revokes.
  Future<void> accept({
    required ReleaseTrust current,
    required int serial,
    required Set<String> revokedKeys,
  }) async {
    final next = {
      'highestSerial': serial > current.highestSerial
          ? serial
          : current.highestSerial,
      'revokedKeys': ({...current.revokedKeys, ...revokedKeys}.toList()
        ..sort()),
    };
    final file = paths.trustRecord;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(next), flush: true);
    await temp.rename(file.path);
  }
}
