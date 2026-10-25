import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';

/// Sends one raw call to the node and returns its `result`, untouched.
abstract interface class ConsoleRepository {
  /// Where calls go, as shown to the user.
  String get endpoint;

  Future<Either<Failure, Object?>> call(String method, List<Object?> params);
}
