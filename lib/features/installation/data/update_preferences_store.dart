import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_update.dart';

/// Update preferences, plus one flag that survives an update's restart.
class UpdatePreferencesStore {
  UpdatePreferencesStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kAuto = 'updates.autoInstall';
  static const _kPostponed = 'updates.postponedUntil';
  static const _kResumeNode = 'updates.resumeNode';

  /// Every key this store writes, for Reset settings.
  static const keys = [_kAuto, _kPostponed, _kResumeNode];

  UpdatePreferences load() {
    final postponed = _prefs.getInt(_kPostponed);
    return UpdatePreferences(
      autoInstall: _prefs.getBool(_kAuto) ?? false,
      postponedUntil: postponed == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(postponed),
    );
  }

  Future<void> save(UpdatePreferences p) async {
    await _prefs.setBool(_kAuto, p.autoInstall);
    final until = p.postponedUntil;
    until == null
        ? await _prefs.remove(_kPostponed)
        : await _prefs.setInt(_kPostponed, until.millisecondsSinceEpoch);
  }

  /// Set when the app quits for an update while its node runs, so the new
  /// version starts the node again.
  bool get resumeNode => _prefs.getBool(_kResumeNode) ?? false;
  Future<void> setResumeNode(bool value) async => value
      ? await _prefs.setBool(_kResumeNode, true)
      : await _prefs.remove(_kResumeNode);
}
