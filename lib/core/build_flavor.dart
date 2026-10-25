import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/domain/bitcoin_network.dart';

/// Production builds are the default. Development builds are made with
/// `--dart-define=FLORESTA_FLAVOR=development`.
enum BuildFlavor {
  production,
  development;

  static const _value = String.fromEnvironment('FLORESTA_FLAVOR');

  static BuildFlavor get compiled =>
      _value == 'development' ? development : production;

  /// Owner decision 3 (2026-10-24): mainnet in production; test networks are
  /// opt-in (advanced settings), and the default in development builds.
  BitcoinNetwork get defaultNetwork => switch (this) {
    production => BitcoinNetwork.bitcoin,
    development => BitcoinNetwork.signet,
  };
}

final buildFlavorProvider = Provider<BuildFlavor>(
  (ref) => BuildFlavor.compiled,
);
