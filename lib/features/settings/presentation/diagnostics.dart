import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/log_buffer.dart';

import '../../../core/providers.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../node/presentation/node_controller.dart';
import 'settings_controller.dart';

/// App version shown in diagnostics; keep in sync with pubspec.yaml.
const appVersion = '0.0.1';

/// What the app reports about itself for support: versions, paths, ports
/// and node state. No wallet data, descriptors or keys.
final diagnosticsRowsProvider = Provider<List<(String, String)>>((ref) {
  final platform = ref.watch(hostPlatformProvider);
  final settings = ref.watch(settingsControllerProvider);
  final env = ref.watch(environmentProvider);
  final detection = ref.watch(installationDetectionProvider).value;
  final status = ref.watch(nodeControllerProvider);
  final dataDir = settings.effectiveDataDir(
    homeDir: env['HOME'] ?? env['USERPROFILE'],
    separator: platform.pathSeparator,
  );
  return [
    ('App version', appVersion),
    ('Platform', platform.label),
    (
      'Floresta',
      detection == null
          ? 'Checking…'
          : detection.match(
              (f) => f.title,
              (i) => '${i.version} at ${i.executablePath}',
            ),
    ),
    ('Network', settings.network.label),
    ('RPC endpoint', settings.rpcEndpoint.toString()),
    ('Electrum (TCP)', '127.0.0.1:${settings.network.electrumPort}'),
    ('Data folder', dataDir),
    if (settings.logToFile)
      ('Log file', '$dataDir${platform.pathSeparator}debug.log'),
    ('Process', status.process.runtimeType.toString()),
    ('API', status.api.name),
    if (status.lastRpcFailure case final f?) ('Last RPC error', f.message),
  ];
});

/// The rows as text, as copied or exported.
final diagnosticsReportProvider = Provider<String>(
  (ref) => ref
      .watch(diagnosticsRowsProvider)
      .map((r) => '${r.$1}: ${r.$2}')
      .join('\n'),
);

/// The file Logs > Export Diagnostics writes: the app report and the
/// daemon output, which [LogBuffer] has already redacted (extended keys).
String diagnosticsFileText({
  required String report,
  required List<String> lines,
  required DateTime now,
}) => [
  'Floresta GUI diagnostics (${now.toIso8601String()})',
  'No wallet data. Extended keys in the log are redacted.',
  '',
  report,
  '',
  'Daemon output (last ${lines.length} lines):',
  ...lines,
].join('\n');
