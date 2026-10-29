import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Whether the sidebar shows icons only. Kept in the app's preferences
/// (`ui.sidebarCompact`), so it survives restarts; "Reset settings" clears it
/// with the other `ui.` keys.
final sidebarCompactProvider = NotifierProvider<SidebarCompact, bool>(
  SidebarCompact.new,
);

class SidebarCompact extends Notifier<bool> {
  static const key = 'ui.sidebarCompact';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(key) ?? false;

  Future<void> toggle() async {
    state = !state;
    await ref.read(sharedPreferencesProvider).setBool(key, state);
  }
}
