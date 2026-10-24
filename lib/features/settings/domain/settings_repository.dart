import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import 'node_settings.dart';

abstract interface class SettingsRepository {
  /// Synchronous so the router can decide the first screen without a frame
  /// of loading UI. Falls back to defaults for missing or corrupt values.
  NodeSettings load();

  Future<Either<Failure, Unit>> save(NodeSettings settings);
}
