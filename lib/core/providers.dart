import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'platform/host_platform.dart';

/// Overridden in `main` once preferences have loaded, so everything below
/// can read settings synchronously.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override sharedPreferencesProvider'),
);

final hostPlatformProvider = Provider<HostPlatform>(
  (ref) => HostPlatform.current(),
);

final environmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});
