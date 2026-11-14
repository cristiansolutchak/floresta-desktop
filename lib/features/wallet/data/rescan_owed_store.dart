import 'package:shared_preferences/shared_preferences.dart';

/// Persists "a wallet rescan is owed" across app restarts, so a
/// rescan requested during sync is not forgotten when the app closes.
class RescanOwedStore {
  RescanOwedStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'wallet.rescanOwedFrom';

  /// The owed rescan, or null when none is owed. `from` is null for "from
  /// the start of the node's filters".
  ({int? from})? read() {
    if (!_prefs.containsKey(_key)) return null;
    final v = _prefs.getInt(_key);
    return (from: v == null || v < 0 ? null : v);
  }

  Future<void> owe({int? from}) => _prefs.setInt(_key, from ?? -1);

  Future<void> clear() => _prefs.remove(_key);
}
