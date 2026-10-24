import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../domain/bitcoin_network.dart';
import '../domain/node_settings.dart';

class NetworkSelector extends StatelessWidget {
  const NetworkSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final BitcoinNetwork value;
  final ValueChanged<BitcoinNetwork> onChanged;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'Network',
      child: RadioGroup<BitcoinNetwork>(
        groupValue: value,
        onChanged: (n) {
          if (n != null) onChanged(n);
        },
        child: Column(
          children: [
            for (final n in BitcoinNetwork.values)
              RadioListTile<BitcoinNetwork>(
                value: n,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(n.label),
                subtitle: Text(n.description),
              ),
            if (value.isMainnet) ...[
              const SizedBox(height: 8),
              const Notice(
                tone: Tone.warning,
                title: 'Mainnet needs time and bandwidth',
                message:
                    'Floresta starts quickly with assumed state and then '
                    'validates history in the background, which uses a lot of '
                    'CPU and bandwidth. Wallet rescans need compact block '
                    'filters, about 11 GB for all of mainnet.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DataDirSelector extends ConsumerWidget {
  const DataDirSelector({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final NodeSettings settings;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(hostPlatformProvider);
    final env = ref.watch(environmentProvider);
    final home = env['HOME'] ?? env['USERPROFILE'];
    final effective = settings.effectiveDataDir(
      homeDir: home,
      separator: platform.pathSeparator,
    );
    return Panel(
      title: 'Data folder',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Chain state, block filters, the watch-only wallet and logs are '
            'stored here. Removing this app never deletes it.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 10),
          KeyValueRow(
            settings.dataDir == null ? 'Default location' : 'Custom location',
            effective,
            mono: true,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  final dir = await getDirectoryPath(
                    confirmButtonText: 'Use this folder',
                  );
                  if (dir != null) onChanged(dir);
                },
                child: const Text('Choose folder…'),
              ),
              if (settings.dataDir != null)
                TextButton(
                  onPressed: () => onChanged(null),
                  child: const Text('Use default'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
