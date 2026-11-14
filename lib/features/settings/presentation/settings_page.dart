import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/advanced_setup.dart';
import '../../installation/presentation/setup_state_provider.dart';
import '../../installation/presentation/updates_panel.dart';
import '../../node/domain/swift_sync.dart';
import '../../node/presentation/node_controller.dart';
import '../domain/node_settings.dart';
import '../domain/wallet_birthday.dart';
import 'diagnostics.dart';
import 'node_settings_widgets.dart';
import 'reset_panel.dart';
import 'settings_controller.dart';
import 'sync_method_labels.dart';

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
        if (settings.useExistingNode) ...[
          Notice(
            tone: Tone.info,
            title: 'Using a node that runs elsewhere',
            message:
                'This app connects to the node at '
                '127.0.0.1:${settings.effectiveRpcPort} and does not start '
                'one, so the data folder and launch options below do not '
                'apply to it.',
            action: OutlinedButton(
              onPressed: () => showAdvancedSetup(context),
              child: const Text('Change…'),
            ),
          ),
          const SizedBox(height: 16),
        ],
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
        SyncMethodPanel(
          settings: settings,
          onSave: (next) => _save(context, ref, next),
        ),
        const SizedBox(height: 16),
        _AdvancedPanel(
          settings: settings,
          onSave: (next) => _save(context, ref, next),
        ),
        const SizedBox(height: 16),
        const UpdatesPanel(),
        const SizedBox(height: 16),
        const _DiagnosticsPanel(),
        const SizedBox(height: 16),
        const ResetPanel(),
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
          if (!s.disableCompactFilters) ...[
            const SizedBox(height: 8),
            _WalletBirthdayField(settings: s, onSave: widget.onSave),
          ],
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

/// How the node gets to the tip. The method is tied to the data
/// folder: a folder that already holds a chain keeps going the way it
/// started, which the panel says instead of pretending a switch applies.
class SyncMethodPanel extends ConsumerStatefulWidget {
  const SyncMethodPanel({
    super.key,
    required this.settings,
    required this.onSave,
  });

  final NodeSettings settings;
  final ValueChanged<NodeSettings> onSave;

  @override
  ConsumerState<SyncMethodPanel> createState() => _SyncMethodPanelState();
}

class _SyncMethodPanelState extends ConsumerState<SyncMethodPanel> {
  late final _origin = TextEditingController(text: widget.settings.hintsOrigin);
  String? _originError;

  @override
  void dispose() {
    _origin.dispose();
    super.dispose();
  }

  void _saveOrigin() {
    final text = _origin.text.trim();
    final value = text.isEmpty ? defaultHintsOrigin : text;
    final problem = hintsOriginProblem(value);
    setState(() => _originError = problem);
    if (problem != null || value == widget.settings.hintsOrigin) return;
    widget.onSave(widget.settings.copyWith(hintsOrigin: value));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final supports = ref.watch(setupStateProvider).installation?.swiftSync;
    final method = s.syncMethod;
    final scheme = Theme.of(context).colorScheme;

    Widget option(SyncMethod m) {
      final why = SyncMethodLabels.unavailable(
        m,
        s.network,
        binarySupportsSwiftSync: supports,
      );
      final selected = method == m;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: why == null || selected,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? scheme.primary : null,
        ),
        title: Text(SyncMethodLabels.title(m)),
        subtitle: Text(
          [SyncMethodLabels.description(m, s.network), ?why].join(' '),
        ),
        selected: selected,
        onTap: why == null && !selected
            ? () => widget.onSave(s.withSyncMethod(m))
            : null,
      );
    }

    return Panel(
      title: 'Sync method',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Applies to a new data folder. A folder that already holds a '
            'chain continues the way it started.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 8),
          if (s.network.supportsSwiftSync) option(SyncMethod.swiftSync),
          if (s.network.assumeUtreexoHeight > 0) option(SyncMethod.fastStart),
          option(SyncMethod.full),
          if (method == SyncMethod.fastStart)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Backfill in background'),
              subtitle: const Text(
                'Re-check the assumed history in the background so nothing '
                'stays assumed.',
              ),
              value: s.backfill,
              onChanged: (v) => widget.onSave(s.copyWith(backfill: v)),
            ),
          if (method == SyncMethod.swiftSync) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _origin,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Hints address',
                hintText: '$defaultHintsOrigin (default)',
                helperText:
                    'The app downloads <address>/${s.network.cliValue} before '
                    'the first start. https only.',
                errorText: _originError,
              ),
              onSubmitted: (_) => _saveOrigin(),
              onTapOutside: (_) => _saveOrigin(),
            ),
          ],
        ],
      ),
    );
  }
}

/// Where wallet history searches (compact filters) begin.
class _WalletBirthdayField extends StatelessWidget {
  const _WalletBirthdayField({required this.settings, required this.onSave});

  final NodeSettings settings;
  final ValueChanged<NodeSettings> onSave;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final start = s.filtersStartHeight;
    final explanation = Text(
      start == null
          ? 'Floresta downloads block filters for the whole chain.'
          : 'Floresta downloads block filters from block ${formatInt(start)}. '
                'Transactions before it are not found. Floresta 0.9.1 applies '
                'this only before its first filter download, so set it before '
                'syncing.',
      style: context.text.bodySmall,
    );
    if (!s.network.isMainnet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Wallet history', style: context.text.titleSmall),
          const SizedBox(height: 4),
          explanation,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: DropdownButtonFormField<int?>(
            initialValue: s.walletBirthdayYear,
            decoration: const InputDecoration(
              labelText: 'Wallet history starts in',
              helperText: 'The year your wallet first received coins',
            ),
            items: [
              const DropdownMenuItem<int?>(
                child: Text('Recent only (smallest download)'),
              ),
              for (final y in WalletBirthday.selectableYears)
                DropdownMenuItem<int?>(value: y, child: Text('$y')),
            ],
            onChanged: (y) =>
                onSave(s.copyWith(walletBirthdayYear: Option.fromNullable(y))),
          ),
        ),
        const SizedBox(height: 6),
        explanation,
      ],
    );
  }
}

class _DiagnosticsPanel extends ConsumerWidget {
  const _DiagnosticsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(diagnosticsRowsProvider);
    final report = ref.watch(diagnosticsReportProvider);

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
