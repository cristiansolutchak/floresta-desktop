import '../../settings/domain/node_settings.dart';

/// Builds the florestad argument list from settings.
///
/// Every flag here exists in `bin/florestad/src/cli.rs`. `--daemon` is never
/// passed: the app supervises the child directly, and daemonizing would
/// detach it and silence stdout.
List<String> florestadLaunchArgs(NodeSettings settings) {
  return [
    '--network',
    settings.network.cliValue,
    if (settings.dataDir case final dir?) ...['--data-dir', dir],
    // Always bind loopback explicitly: the RPC has no authentication.
    '--rpc-address',
    '127.0.0.1:${settings.effectiveRpcPort}',
    if (settings.logToFile) '--log-to-file',
    if (settings.disableCompactFilters) '--no-cfilters',
    if (settings.filtersStartHeight case final h?) ...[
      '--filters-start-height',
      '$h',
    ],
  ];
}
