import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../shared/format.dart';
import '../../../shared/widgets/common.dart';
import '../domain/app_update.dart';
import 'update_controller.dart';

/// The update notice under the header, on every screen. Shows only when
/// there is something to say: an offer (until "Later"), a download, a
/// verified update waiting, a florestad that needs a node restart, or the
/// outcome of the last update.
class UpdateBar extends ConsumerWidget {
  const UpdateBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updateControllerProvider);
    if (!u.visibleAt(DateTime.now())) return const SizedBox.shrink();
    final c = ref.read(updateControllerProvider.notifier);
    final content = _content(context, u, c);
    if (content == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: content,
    );
  }

  Widget? _content(BuildContext context, UpdateCenter u, UpdateController c) {
    final buttons = <Widget>[];
    Widget actions() => Wrap(spacing: 8, runSpacing: 8, children: buttons);

    if (u.updated case final r?) {
      buttons.add(
        TextButton(onPressed: c.dismissUpdated, child: const Text('OK')),
      );
      return r.ok && r.version == appVersionText
          ? Notice(
              tone: Tone.success,
              icon: Icons.check_circle_outline,
              title: 'Floresta Desktop was updated to ${r.version}',
              message:
                  'Your settings, wallets and node data were kept as they '
                  'were.',
              action: actions(),
            )
          : Notice(
              tone: Tone.danger,
              icon: Icons.error_outline,
              title: 'The update to ${r.version} did not complete',
              message:
                  '${r.reason?.isNotEmpty ?? false ? '${r.reason![0].toUpperCase()}${r.reason!.substring(1)}. ' : ''}'
                  'You are still on $appVersionText, and nothing else '
                  'changed.',
              action: actions(),
            );
    }

    switch (u.phase) {
      case AppUpdatePhase.downloading:
        final total = u.total ?? 0;
        final got = u.received ?? 0;
        buttons.add(
          TextButton(onPressed: c.cancelDownload, child: const Text('Cancel')),
        );
        return Notice(
          tone: Tone.info,
          icon: Icons.downloading,
          title: 'Downloading Floresta Desktop ${u.app?.version}',
          message: total > 0
              ? '${formatBytes(got)} of ${formatBytes(total)}. It is checked '
                    'against the signed release before anything changes.'
              : 'Starting the download…',
          action: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(
                    value: (got / total).clamp(0.0, 1.0),
                    semanticsLabel: 'Update download',
                  ),
                ),
              actions(),
            ],
          ),
        );
      case AppUpdatePhase.ready:
        buttons.add(
          FilledButton(
            onPressed: c.updateAppNow,
            child: const Text('Restart now'),
          ),
        );
        return Notice(
          tone: Tone.info,
          icon: Icons.system_update_alt,
          title: 'Floresta Desktop ${u.app?.version} is ready',
          message:
              'Downloaded and verified. It is installed when you quit '
              'Floresta Desktop, or now if you restart. A running node is '
              'stopped cleanly and started again.',
          action: actions(),
        );
      case AppUpdatePhase.restarting:
        return const Notice(
          tone: Tone.info,
          icon: Icons.restart_alt,
          title: 'Restarting to finish the update',
          message: 'Stopping the node cleanly first. This can take a moment.',
        );
      case AppUpdatePhase.handedToSystem:
        return Notice(
          tone: Tone.info,
          icon: Icons.system_update_alt,
          title: 'Finish in your package installer',
          message:
              'The verified package for Floresta Desktop ${u.app?.version} is '
              'open in your system\'s installer, which asks for your '
              'password. Restart Floresta Desktop afterwards.',
        );
      case AppUpdatePhase.idle:
        break;
    }

    if (u.nodeRestartNeeded) {
      buttons.add(
        FilledButton(
          onPressed: c.restartNode,
          child: const Text('Restart node'),
        ),
      );
      return Notice(
        tone: Tone.info,
        icon: Icons.restart_alt,
        title: 'The new Floresta is installed',
        message:
            'Your node still runs the previous one. Restart it to switch; '
            'sync progress is kept.',
        action: actions(),
      );
    }

    final app = u.app;
    final node = u.florestad;
    if (app == null && node == null) return null;
    final lines = <String>[
      if (app != null)
        'Floresta Desktop ${app.version} is available (you have ${app.current}).'
            '${app.manifest.notes.isEmpty ? '' : ' ${app.manifest.notes}'}',
      if (node != null)
        'Floresta ${node.label} is available (you have ${node.currentLabel}).',
      if (app != null)
        switch (app.kind) {
          NotUpdatable(:final reason) =>
            '$reason Download the new version from the release page.',
          _ when app.artifact == null =>
            'It is not published for this kind of installation yet.',
          _ => 'Your settings, wallets and node data are kept.',
        },
    ];
    final canUpdateApp =
        app != null && app.artifact != null && app.kind is! NotUpdatable;
    if (canUpdateApp) {
      buttons.add(
        FilledButton(
          onPressed: c.updateAppNow,
          child: Text(
            app.kind is SystemPackage ? 'Download and install' : 'Update now',
          ),
        ),
      );
    }
    if (node != null) {
      buttons.add(
        canUpdateApp
            ? OutlinedButton(
                onPressed: c.installFlorestad,
                child: const Text('Update Floresta'),
              )
            : FilledButton(
                onPressed: c.installFlorestad,
                child: const Text('Update Floresta'),
              ),
      );
    }
    buttons.add(TextButton(onPressed: c.postpone, child: const Text('Later')));
    return Notice(
      tone: Tone.info,
      icon: Icons.system_update_alt,
      title: 'An update is available',
      message: lines.join('\n'),
      action: actions(),
    );
  }
}
