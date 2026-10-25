import 'dart:io';

import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';

/// Writes a text file the user chose a location for (diagnostics export).
/// Never used for the data folder or chain state.
Future<Either<Failure, Unit>> writeTextFile(String path, String text) async {
  try {
    await File(path).writeAsString(text, flush: true);
    return const Right(unit);
  } on FileSystemException catch (e) {
    return Left(FileWriteFailure(path, e.osError?.message ?? e.message));
  }
}
