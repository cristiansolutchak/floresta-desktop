import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The bundled font's licence, listed with the packages' licences.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Space Grotesk',
    ], await rootBundle.loadString('assets/fonts/Space_Grotesk/OFL.txt'));
  });
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      // Riverpod 3 retries failed providers by default. Failures here are
      // returned as values (Either), and a retry loop would re-spawn
      // `florestad --version` probes, so retries are disabled.
      retry: (retryCount, error) => null,
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const FlorestaApp(),
    ),
  );
}
