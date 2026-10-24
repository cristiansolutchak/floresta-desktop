import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../node/presentation/node_controller.dart';
import '../domain/node_settings.dart';
import 'node_settings_widgets.dart';
import 'settings_controller.dart';

/// App version shown in diagnostics; keep in sync with pubspec.yaml.
const appVersion = '0.1.0';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    NodeSettings next,
  ) async {
    final result = await ref
        .read(settingsControllerProvider.notifier)
        .update(next);
    if (!context.mounted) return;
    result.fold((f) => showFailure(context, f), (_) {});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final nodeActive = ref.watch(
      nodeControllerProvider.select((s) => s.process.isActive),
    );

    return PageBody(
      children: [
        const PageHeader(
          title: 'Settings',
          subtitle: 'How Floresta is started and where it keeps data.',
        ),
        if (nodeActive) ...[
          const Notice(
            tone: Tone.warning,
            title: 'The node is running',
            message:
                'Changes take effect the next time the node starts. '
                'Restart it from Node to apply them now.',
          ),
          const SizedBox(height: 16),
        ],
        NetworkSelector(
          value: settings.network,
          onChanged: (n) => _save(context, ref, settings.copyWith(network: n)),
        ),
        const SizedBox(height: 16),
        DataDirSelector(
          settings: settings,
          onChanged: (dir) => _save(
            context,
            ref,
            settings.copyWith(dataDir: Option.fromNullable(dir)),
          ),
        ),
        const SizedBox(height: 16),
        _AdvancedPanel(
          settings: settings,
          onSave: (next) => _save(context, ref, next),
        ),
        const SizedBox(height: 16),
        const _DiagnosticsPanel(),
      ],
    );
  }
}

class _AdvancedPanel extends StatefulWidget {
  const _AdvancedPanel({required this.settings, required this.onSave});

  final NodeSettings settings;
  final ValueChanged<NodeSettings> onSave;

  @override
  State<_AdvancedPanel> createState() => _AdvancedPanelState();
}

class _AdvancedPanelState extends State<_AdvancedPanel> {
  late final _port = TextEditingController(
    text: widget.settings.rpcPort?.toString() ?? '',
  );

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _savePort() {
    final text = _port.text.trim();
    final port = int.tryParse(text);
    if (text.isNotEmpty && port == null) return;
    widget.onSave(widget.settings.copyWith(rpcPort: Option.fromNullable(port)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Panel(
      title: 'Advanced',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'RPC port',
                    hintText: '${s.network.rpcPort} (default)',
                    helperText: 'Always bound to 127.0.0.1',
                  ),
                  onSubmitted: (_) => _savePort(),
                  onTapOutside: (_) => _savePort(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Write a log file'),
            subtitle: const Text(
              'Saves debug.log in the data folder. Floresta does not rotate '
              'this file, so it grows over time.',
            ),
            value: s.logToFile,
            onChanged: (v) => widget.onSave(s.copyWith(logToFile: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Disable compact block filters'),
            subtitle: const Text(
              'Saves disk space, but wallet rescans and adding descriptors '
              'will no longer work.',
            ),
            value: s.disableCompactFilters,
            onChanged: (v) =>
                widget.onSave(s.copyWith(disableCompactFilters: v)),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsPanel extends ConsumerWidget {
  const _DiagnosticsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
    final settings = ref.watch(settingsControllerProvider);
    final env = ref.watch(environmentProvider);
    final detection = ref.watch(installationDetectionProvider).value;
    final status = ref.watch(nodeControllerProvider);
    final dataDir = settings.effectiveDataDir(
      homeDir: env['HOME'] ?? env['USERPROFILE'],
      separator: platform.pathSeparator,
    );

    final rows = <(String, String)>[
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
    final report = rows.map((r) => '${r.$1}: ${r.$2}').join('\n');

    return Panel(
      title: 'Diagnostics',
      trailing: CopyButton(text: report, tooltip: 'Copy diagnostics'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (k, v) in rows) KeyValueRow(k, v, mono: true),
          const SizedBox(height: 8),
          Text(
            'Diagnostics contain no wallet information and are safe to '
            'share when asking for help.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.go('/installation'),
              child: const Text('Installation details'),
            ),
          ),
        ],
      ),
    );
  }
}
