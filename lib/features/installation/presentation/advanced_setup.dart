import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/build_flavor.dart';
import '../../../shared/widgets/common.dart';
import '../../node/domain/blockchain_info.dart';
import '../../node/domain/node_readiness.dart';
import '../../node/presentation/node_controller.dart';
import '../../node/presentation/status_labels.dart' show formatInt;
import '../../settings/domain/bitcoin_network.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/existing_node_probe.dart';
import '../domain/existing_node.dart';
import 'installation_providers.dart';
import 'installation_view.dart';

/// Advanced setup: reuse a florestad of your own, or connect to a node that
/// already runs (Docker, a Nix service, a terminal).
Future<void> showAdvancedSetup(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _AdvancedSetupDialog(),
);

enum _Way { executable, running }

class _AdvancedSetupDialog extends ConsumerStatefulWidget {
  const _AdvancedSetupDialog();

  @override
  ConsumerState<_AdvancedSetupDialog> createState() =>
      _AdvancedSetupDialogState();
}

class _AdvancedSetupDialogState extends ConsumerState<_AdvancedSetupDialog> {
  _Way _way = _Way.executable;

  @override
  void initState() {
    super.initState();
    if (ref.read(settingsControllerProvider).useExistingNode) {
      _way = _Way.running;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget choice(_Way way, IconData icon, String title, String subtitle) {
      final selected = _way == way;
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Semantics(
          selected: selected,
          button: true,
          child: Material(
            color: selected
                ? scheme.primary.withValues(alpha: 0.05)
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: selected ? scheme.primary : context.colors.border,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _way = way),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected ? scheme.primary : context.colors.muted,
                    ),
                    const SizedBox(width: 12),
                    Icon(icon, size: 20, color: scheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: context.text.titleSmall),
                          Text(subtitle, style: context.text.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Advanced setup',
                        style: context.text.headlineSmall,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'For a Floresta you already run or built yourself.',
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.muted,
                ),
              ),
              const SizedBox(height: 20),
              choice(
                _Way.executable,
                Icons.terminal,
                'Use a florestad on this computer',
                'One you built with cargo or installed with Nix. The app runs '
                    'it for you.',
              ),
              choice(
                _Way.running,
                Icons.lan_outlined,
                'Connect to a node that is already running',
                'In Docker, as a Nix service or in a terminal. The app does '
                    'not start it.',
              ),
              const SizedBox(height: 8),
              switch (_way) {
                _Way.executable => const _ExecutableChoice(),
                _Way.running => const _RunningNodeChoice(),
              },
            ],
          ),
        ),
      ),
    );
  }
}

class _ExecutableChoice extends ConsumerWidget {
  const _ExecutableChoice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detection = ref.watch(installationDetectionProvider);
    final configured = ref.watch(
      settingsControllerProvider.select((s) => s.executablePath),
    );
    final existing = ref.watch(
      settingsControllerProvider.select((s) => s.useExistingNode),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'The app already looks on PATH, in ~/.cargo/bin, Homebrew and the '
          'Nix profiles (~/.nix-profile, /run/current-system/sw). For '
          'anything else, such as a `nix build` result, choose the florestad '
          'file itself, not its folder.',
          style: context.text.bodySmall,
        ),
        const SizedBox(height: 12),
        switch (detection) {
          AsyncData(:final value) => value.match(
            (f) => Notice(
              tone: Tone.warning,
              title: f.title,
              message: failureLine(f),
            ),
            (i) => StatusIndicator(
              label: 'Using florestad ${i.version}',
              caption: '${i.source.label}: ${i.executablePath}',
              tone: Tone.success,
            ),
          ),
          _ => const Text('Looking for florestad…'),
        },
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => chooseExecutable(context, ref),
              child: const Text('Choose florestad…'),
            ),
            if (configured != null)
              OutlinedButton(
                onPressed: () => setExecutable(context, ref, null),
                child: const Text('Use automatic detection'),
              ),
            if (existing)
              OutlinedButton(
                onPressed: () async {
                  final c = ref.read(settingsControllerProvider.notifier);
                  final s = ref.read(settingsControllerProvider);
                  final r = await c.update(s.copyWith(useExistingNode: false));
                  if (context.mounted) {
                    r.fold((f) => showFailure(context, f), (_) {});
                  }
                },
                child: const Text('Run Floresta with this app again'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Connection check for a node that runs elsewhere. Nothing is saved until
/// the RPC answered as Floresta on the chosen network.
class _RunningNodeChoice extends ConsumerStatefulWidget {
  const _RunningNodeChoice();

  @override
  ConsumerState<_RunningNodeChoice> createState() => _RunningNodeChoiceState();
}

class _RunningNodeChoiceState extends ConsumerState<_RunningNodeChoice> {
  late BitcoinNetwork _network = ref.read(settingsControllerProvider).network;
  late final _port = TextEditingController(
    text: '${ref.read(settingsControllerProvider).effectiveRpcPort}',
  );
  bool _checking = false;
  bool _saving = false;
  DockerScan? _docker;
  ExistingNodeCheck? _check;
  int? _checkedPort;
  String? _portError;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  int? _parsedPort() {
    final p = int.tryParse(_port.text.trim());
    return p != null && p >= 1024 && p <= 65535 ? p : null;
  }

  Future<void> _run() async {
    final port = _parsedPort();
    if (port == null) {
      setState(() => _portError = 'A port between 1024 and 65535');
      return;
    }
    setState(() {
      _portError = null;
      _checking = true;
      _check = null;
    });
    final (docker, check) = await (
      ref.read(dockerProbeProvider).scan(),
      ref.read(existingNodeProbeProvider).check(_network, port),
    ).wait;
    if (!mounted) return;
    setState(() {
      _checking = false;
      _docker = docker;
      _check = check;
      _checkedPort = port;
    });
  }

  Future<void> _use() async {
    final port = _checkedPort;
    if (port == null) return;
    setState(() => _saving = true);
    final controller = ref.read(settingsControllerProvider.notifier);
    final current = ref.read(settingsControllerProvider);
    final result = await controller.update(
      current.copyWith(
        useExistingNode: true,
        network: _network,
        rpcPort: Option.fromNullable(port == _network.rpcPort ? null : port),
        onboardingComplete: true,
      ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.getLeft().toNullable() case final f?) {
      showFailure(context, f);
      return;
    }
    await ref.read(nodeControllerProvider.notifier).refresh();
    if (!mounted) return;
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go('/node');
  }

  @override
  Widget build(BuildContext context) {
    final showTest =
        ref.watch(buildFlavorProvider) == BuildFlavor.development ||
        !_network.isMainnet;
    final check = _check;
    final rpcOk = check?.rpc.isRight() ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'The app reaches the node on this computer at 127.0.0.1. Use the '
          'port the node\'s RPC is published on.',
          style: context.text.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<BitcoinNetwork>(
                initialValue: _network,
                decoration: const InputDecoration(labelText: 'Network'),
                items: [
                  for (final n in BitcoinNetwork.values)
                    if (n.isMainnet || showTest)
                      DropdownMenuItem(value: n, child: Text(n.label)),
                ],
                onChanged: (n) {
                  if (n == null) return;
                  setState(() {
                    // Follow the network's default unless a port was typed.
                    if (_port.text.trim() == '${_network.rpcPort}') {
                      _port.text = '${n.rpcPort}';
                    }
                    _network = n;
                    _check = null;
                  });
                },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'RPC port',
                  errorText: _portError,
                ),
                onChanged: (_) => setState(() => _check = null),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: _checking ? null : _run,
              child: Text(_checking ? 'Checking…' : 'Check connection'),
            ),
            FilledButton(
              onPressed: rpcOk && !_saving ? _use : null,
              child: const Text('Use this node'),
            ),
          ],
        ),
        if (check != null) ...[
          const SizedBox(height: 16),
          _CheckResult(
            check: check,
            docker: _docker,
            network: _network,
            port: _checkedPort!,
          ),
        ],
        const SizedBox(height: 16),
        const Notice(
          tone: Tone.warning,
          title: 'Keep the RPC on this computer',
          message:
              'florestad\'s RPC has no password. In Docker, start florestad '
              'with --rpc-address 0.0.0.0:8332 --electrum-address '
              '0.0.0.0:50001 (it listens on 127.0.0.1 inside the container '
              'otherwise) and publish the ports as -p 127.0.0.1:8332:8332 '
              '-p 127.0.0.1:50001:50001, never on all interfaces.',
        ),
      ],
    );
  }
}

class _CheckResult extends StatelessWidget {
  const _CheckResult({
    required this.check,
    required this.docker,
    required this.network,
    required this.port,
  });

  final ExistingNodeCheck check;
  final DockerScan? docker;
  final BitcoinNetwork network;
  final int port;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      check.rpc.match(
        (f) => StatusIndicator(
          label: 'No Floresta node at 127.0.0.1:$port',
          caption: failureLine(f),
          tone: Tone.danger,
        ),
        (BlockchainInfo info) => StatusIndicator(
          label: 'Floresta answers on ${network.label}',
          caption:
              '${formatInt(info.headerHeight)} headers, '
              '${formatInt(info.validatedHeight)} blocks verified',
          tone: Tone.success,
        ),
      ),
      if (check.rpc.isRight())
        switch (check.electrum) {
          ElectrumCheck.ok => StatusIndicator(
            label: 'Electrum server answers',
            caption: '127.0.0.1:${network.electrumPort}, for your wallets',
            tone: Tone.success,
          ),
          ElectrumCheck.wrongNetwork => StatusIndicator(
            label: 'The Electrum server is on another network',
            caption: '127.0.0.1:${network.electrumPort}',
            tone: Tone.danger,
          ),
          ElectrumCheck.unreachable || ElectrumCheck.unknown => StatusIndicator(
            label: 'No Electrum server at 127.0.0.1:${network.electrumPort}',
            caption:
                'The node works, but the wallet screen and your wallets need '
                'it on this port. Publish it too.',
            tone: Tone.warning,
          ),
        },
      ...switch (docker) {
        null || DockerNotFound() => const <Widget>[],
        DockerUnavailable(:final detail) => [
          StatusIndicator(
            label: 'Docker did not answer',
            caption: detail,
            tone: Tone.neutral,
          ),
        ],
        DockerContainers(:final containers) when containers.isEmpty => [
          const StatusIndicator(
            label: 'No Floresta container in Docker',
            tone: Tone.neutral,
          ),
        ],
        DockerContainers(:final containers) => [
          for (final c in containers) _container(c),
        ],
      },
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: r),
      ],
    );
  }

  Widget _container(DockerContainer c) {
    final published = c.onHostPort(port);
    final (label, caption, tone) = !c.running
        ? (
            'Container ${c.name} is not running',
            '${c.status}. Start it with: docker start ${c.name}',
            Tone.warning,
          )
        : published == null
        ? (
            'Container ${c.name} does not publish port $port',
            'Publish it with -p 127.0.0.1:$port:$port, and start florestad '
                'with --rpc-address 0.0.0.0:$port inside.',
            Tone.warning,
          )
        : published.onAllInterfaces
        ? (
            'Container ${c.name} publishes port $port on every interface',
            'Other computers on your network can reach the RPC, which has no '
                'password. Publish it as 127.0.0.1:$port:${published.containerPort}.',
            Tone.danger,
          )
        : (
            'Container ${c.name} is running',
            '${c.image}, port $port on 127.0.0.1',
            Tone.success,
          );
    return StatusIndicator(label: label, caption: caption, tone: tone);
  }
}

/// Every way to get Floresta running, each with when it fits. Second place on
/// purpose: most people need only the main action.
Future<void> showOtherWays(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialog) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Other ways to connect',
                      style: dialog.text.headlineSmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(dialog).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _WayRow(
              icon: Icons.download_outlined,
              title: 'Install automatically',
              when: 'Recommended for most people.',
              body:
                  'The main button installs the official release after '
                  'checking its signature and checksum.',
            ),
            const _WayRow(
              icon: Icons.terminal,
              title: 'Use a florestad you already have',
              when: 'If you built it with cargo or installed it with Nix.',
              body:
                  'Found automatically in ~/.cargo/bin, Homebrew and the Nix '
                  'profiles. Otherwise choose the file in Advanced setup.',
            ),
            const _WayRow(
              icon: Icons.lan_outlined,
              title: 'Connect to a node that is already running',
              when:
                  'If Floresta runs in Docker, as a Nix service or in a '
                  'terminal.',
              body:
                  'In Advanced setup, enter its RPC port. The app checks that '
                  'Floresta answers there before using it. Keep the port on '
                  '127.0.0.1: the RPC has no password.',
            ),
            const _WayRow(
              icon: Icons.build_outlined,
              title: 'If the automatic install fails',
              when: 'Nothing is installed unless every check passes.',
              body:
                  '• Check the internet connection, then Try again: a paused '
                  'download resumes where it stopped.\n'
                  '• A failed signature or checksum means the download was '
                  'refused for your safety; trying later usually helps.\n'
                  '• Logs → Export Diagnostics saves a report for support, '
                  'with keys removed.',
            ),
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(dialog).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Build from source', style: dialog.text.titleSmall),
                children: const [BuildFromSource()],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () {
                  Navigator.of(dialog).pop();
                  showAdvancedSetup(context);
                },
                child: const Text('Open Advanced setup'),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _WayRow extends StatelessWidget {
  const _WayRow({
    required this.icon,
    required this.title,
    required this.when,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String when;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                Text(
                  when,
                  style: context.text.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
