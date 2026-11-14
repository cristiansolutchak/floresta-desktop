import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Production builds are the default. Development builds are made with
/// `--dart-define=FLORESTA_FLAVOR=development`.
enum BuildFlavor {
  production,
  development;

  static const _value = String.fromEnvironment('FLORESTA_FLAVOR');

  static BuildFlavor get compiled =>
      _value == 'development' ? development : production;
}

final buildFlavorProvider = Provider<BuildFlavor>(
  (ref) => BuildFlavor.compiled,
);
