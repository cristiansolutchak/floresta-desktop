import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/app_version.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/common.dart';
import '../domain/app_update.dart';
import 'installation_providers.dart';
import 'update_controller.dart';

/// Settings → Updates: versions, the automatic-install preference, a
/// manual check and the last result.
class UpdatesPanel extends ConsumerWidget {
  const UpdatesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateControllerProvider);
    final c = ref.read(updateControllerProvider.notifier);
    final florestad = ref
        .watch(installationDetectionProvider)
        .value
        ?.toNullable();
    final hasSource = ref.watch(appUpdaterProvider) != null;
    final kindNote = switch (u.kind) {
      SelfUpdatable() => 'Floresta GUI updates itself in place.',
      SystemPackage() =>
        'Installed as a system package: updates are downloaded and verified '
            'here, then installed by your system\'s package installer.',
      NotUpdatable(:final reason) => reason,
    };
    final last = u.lastChecked;
    final status = u.checking
        ? 'Checking…'
        : last == null
        ? 'Not checked yet in this session.'
        : u.app == null && u.florestad == null && u.failure == null
        ? 'Up to date (checked ${formatDuration(DateTime.now().difference(last))} ago).'
        : 'Checked ${formatDuration(DateTime.now().difference(last))} ago.';

    return Panel(
      title: 'Updates',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Floresta GUI $appVersionText', style: context.text.titleSmall),
          Text(
            florestad == null
                ? 'Floresta: not installed by this app'
                : 'Floresta ${florestad.versionLabel}',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(kindNote, style: context.text.bodySmall),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Install updates automatically'),
            subtitle: const Text(
              'Off: the app checks when it starts, then asks before '
              'installing. On: a new Floresta is installed right away (the '
              'node switches at its next restart), and a new Floresta GUI '
              'is installed when you quit it. Every update is verified '
              'against the signed release first.',
            ),
            value: u.preferences.autoInstall,
            onChanged: hasSource ? c.setAutoInstall : null,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: hasSource && !u.checking ? c.check : null,
                child: const Text('Check now'),
              ),
              Text(
                hasSource ? status : 'This build has no release source.',
                style: context.text.bodySmall,
              ),
            ],
          ),
          if (u.failure case final f?) ...[
            const SizedBox(height: 12),
            Notice.failure(f),
          ],
        ],
      ),
    );
  }
}
