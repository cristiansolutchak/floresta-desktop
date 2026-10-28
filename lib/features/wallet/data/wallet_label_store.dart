import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/wallet_labels.dart';

/// Wallet names and removals, in the app's preferences (`wallet.labels`,
/// cleared by Reset settings with the other `wallet.` keys). Keys are account
/// ids (hashes), values names the user typed: no descriptors or keys.
class WalletLabelStore {
  WalletLabelStore(this._prefs);

  final SharedPreferences _prefs;
  static const key = 'wallet.labels';

  Map<String, WalletLabel> read() {
    final raw = _prefs.getString(key);
    if (raw == null) return const {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String) key: WalletLabel.fromJson(value),
      };
    } on FormatException {
      return const {};
    }
  }

  Future<void> write(Map<String, WalletLabel> labels) => _prefs.setString(
    key,
    jsonEncode({
      for (final MapEntry(:key, :value) in labels.entries)
        if (value != const WalletLabel()) key: value.toJson(),
    }),
  );
}
