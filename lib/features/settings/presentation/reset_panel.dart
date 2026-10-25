import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../shared/widgets/common.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../node/domain/node_status.dart';
import '../../node/presentation/node_controller.dart';
import '../../wallet/presentation/wallet_rescan_controller.dart';
import '../data/app_reset_service.dart';
import 'settings_controller.dart';

final appResetServiceProvider = Provider<AppResetService>(
  (ref) => AppResetService(
    prefs: ref.watch(sharedPreferencesProvider),
    paths: ref.watch(appPathsProvider),
  ),
);

/// INS-12: three separate resets, plus what uninstalling the app leaves.
/// Every action needs the node stopped and an explicit confirmation.
class ResetPanel extends ConsumerWidget {
  const ResetPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(appResetServiceProvider);
    final settings = ref.watch(settingsControllerProvider);
    final platform = ref.watch(hostPlatformProvider);
    final env = ref.watch(environmentProvider);
    final paths = ref.watch(appPathsProvider);
    final status = ref.watch(nodeControllerProvider);
    final nodeUp =
        status.process.isActive || status.api == ApiReachability.reachable;
    final dataDir = settings.effectiveDataDir(
      homeDir: env['HOME'] ?? env['USERPROFILE'],
      separator: platform.pathSeparator,
    );
    final managed = service.managedFloresta.isNotEmpty;

    Future<void> run(Future<void> Function() action) async {
      if (nodeUp) {
        showMessage(context, 'Stop the node first, then try again.');
        return;
      }
      await action();
    }

    Widget row({
      required String title,
      required String body,
      required String button,
      required VoidCallback? onPressed,
      bool danger = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton(
            style: danger
                ? OutlinedButton.styleFrom(
                    foregroundColor: context.colors.danger,
                  )
                : null,
            onPressed: onPressed,
            child: Text(button),
          ),
        ],
      ),
    );

    return Panel(
      title: 'Reset and uninstall',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (nodeUp) ...[
            const Notice(
              tone: Tone.info,
              title: 'The node is running',
              message: 'Stop it from Node before resetting anything here.',
            ),
            const SizedBox(height: 16),
          ],
          row(
            title: 'Reset app settings',
            body:
                'Forgets this app\'s choices (network, folders, options) and '
                'shows the setup wizard again. Floresta and your node data '
                'stay.',
            button: 'Reset settings…',
            onPressed: nodeUp
                ? null
                : () => run(() => _resetSettings(context, ref, service)),
          ),
          row(
            title: 'Remove the Floresta this app installed',
            body: managed
                ? 'Deletes the florestad copies in ${paths.versions.path}. A '
                      'florestad you chose or built yourself is not touched, '
                      'and neither is your node data.'
                : 'This app has not installed Floresta on this computer.',
            button: 'Remove Floresta…',
            onPressed: nodeUp || !managed
                ? null
                : () => run(() => _removeFloresta(context, ref, service)),
          ),
          row(
            title: 'Delete node data for ${settings.network.label}',
            body:
                'Removes the chain state, block filters, the watch-only '
                'wallet and the log in $dataDir. Floresta has to sync again, '
                'and watched wallets must be added again.',
            button: 'Delete node data…',
            danger: true,
            onPressed: nodeUp
                ? null
                : () => run(() => _deleteData(context, ref, service, dataDir)),
          ),
          const Divider(),
          const SizedBox(height: 12),
          Text('Uninstalling the app', style: context.text.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Quit the app and move it to the Trash. That never deletes '
            'anything else; to remove everything, first use the actions above, '
            'then delete these folders yourself:',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 8),
          KeyValueRow('App data', paths.root.path, mono: true),
          KeyValueRow('Node data', dataDir, mono: true),
        ],
      ),
    );
  }

  Future<void> _resetSettings(
    BuildContext context,
    WidgetRef ref,
    AppResetService service,
  ) async {
    final ok = await confirm(
      context,
      title: 'Reset app settings?',
      message:
          'The network, folder and option choices are forgotten and the '
          'setup wizard opens. Floresta and the node data are kept.',
      confirmLabel: 'Reset settings',
    );
    if (!ok || !context.mounted) return;
    final result = await service.resetSettings();
    if (!context.mounted) return;
    result.fold((f) => showFailure(context, f), (_) {
      ref
        ..invalidate(settingsControllerProvider)
        ..invalidate(installationDetectionProvider)
        ..invalidate(walletRescanProvider);
      context.go('/welcome');
    });
  }

  Future<void> _removeFloresta(
    BuildContext context,
    WidgetRef ref,
    AppResetService service,
  ) async {
    final ok = await confirm(
      context,
      title: 'Remove the installed Floresta?',
      message:
          'Deletes ${ref.read(appPathsProvider).versions.path}. You can '
          'install it again from Installation. Your node data is kept.',
      confirmLabel: 'Remove Floresta',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final result = await service.removeManagedFloresta();
    if (!context.mounted) return;
    result.fold((f) => showFailure(context, f), (_) {
      ref.invalidate(installationDetectionProvider);
      showMessage(context, 'The installed Floresta was removed.');
    });
  }

  Future<void> _deleteData(
    BuildContext context,
    WidgetRef ref,
    AppResetService service,
    String dataDir,
  ) async {
    final plan = service.chainDataIn(dataDir);
    if (plan.getLeft().toNullable() case final f?) {
      showFailure(context, f);
      return;
    }
    final names = plan.getOrElse((_) => const []);
    final ok = await confirm(
      context,
      title: 'Delete the node data?',
      message:
          'This permanently deletes ${names.join(', ')} from $dataDir:\n\n'
          '• the validated chain state, so Floresta syncs again;\n'
          '• the compact block filters, downloaded again;\n'
          '• the watch-only wallet: watched descriptors must be added '
          'again (no keys are stored, so no funds are affected).\n\n'
          'Other files in that folder are kept.',
      confirmLabel: 'Delete node data',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final result = await service.deleteChainData(dataDir);
    if (!context.mounted) return;
    result.fold(
      (f) => showFailure(context, f),
      (deleted) => showMessage(
        context,
        'Deleted ${deleted.length} items from $dataDir.',
      ),
    );
  }
}
