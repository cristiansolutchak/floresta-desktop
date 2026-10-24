import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/errors/failure.dart';
import '../../../core/providers.dart';
import '../data/shared_prefs_settings_repository.dart';
import '../domain/node_settings.dart';
import '../domain/settings_repository.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SharedPrefsSettingsRepository(ref.watch(sharedPreferencesProvider)),
);

final settingsControllerProvider =
    NotifierProvider<SettingsController, NodeSettings>(SettingsController.new);

class SettingsController extends Notifier<NodeSettings> {
  @override
  NodeSettings build() => ref.watch(settingsRepositoryProvider).load();

  /// Persists first and only then updates state, so the UI never shows a
  /// value that failed validation or was not saved.
  Future<Either<Failure, Unit>> update(NodeSettings next) async {
    final saved = await ref.read(settingsRepositoryProvider).save(next);
    if (saved.isRight()) state = next;
    return saved;
  }
}
