import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../installation/domain/next_action.dart';
import '../../installation/presentation/installation_providers.dart';
import '../../settings/presentation/diagnostics.dart';
import '../../settings/presentation/settings_controller.dart';

/// Help: the installed node and a glossary.
class HelpPage extends ConsumerWidget {
  const HelpPage({super.key});

  static const glossary = [
    ('Node', 'A computer running software to validate Bitcoin rules.'),
    ('Utreexo', 'A cryptographic accumulator that makes the UTXO set tiny.'),
    ('Backfill', 'Background verification of historical blocks after startup.'),
    ('Electrum', 'A protocol used by lightweight wallets to talk to nodes.'),
    ('RPC', 'Remote Procedure Call. How developers talk to the node.'),
    ('Metrics', 'Data stream (Prometheus) for monitoring performance.'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(
      settingsControllerProvider.select((s) => s.network),
    );
    final version = switch (ref.watch(nextActionProvider).value) {
      OpenNodeManagement(:final installation) ||
      ConfigureNode(:final installation) ||
      UpdateFloresta(:final installation) => installation.versionLabel,
      _ => 'Not installed',
    };

    return DashPage(
      children: [
        DashPageHeader(
          asset: DashIcons.help,
          title: 'Floresta Node',
          subtitle: '$version  •  ${network.label}',
          actions: [
            DashButton(
              'Licences',
              style: DashButtonStyle.secondary,
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Floresta Desktop',
                applicationVersion: appVersion,
                applicationLegalese:
                    'MIT OR Apache-2.0. florestad is MIT OR Apache-2.0, '
                    '© The Floresta Project Developers.',
              ),
            ),
            DashButton(
              'Logs',
              style: DashButtonStyle.secondary,
              onPressed: () => context.go('/logs'),
            ),
            DashButton(
              'Copy Diagnostics',
              style: DashButtonStyle.primary,
              asset: DashIcons.copy,
              tooltip: 'App details for a support request; no wallet data',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: ref.read(diagnosticsReportProvider)),
                );
                if (context.mounted) showMessage(context, 'Diagnostics copied');
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        Semantics(
          header: true,
          child: Text(
            'Glossary',
            style: DashText.cardTitle(context).copyWith(fontSize: 16),
          ),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < glossary.length; i += 2) ...[
          DashColumns(
            gap: 16,
            minChildWidth: 300,
            children: [
              for (final (term, meaning) in glossary.skip(i).take(2))
                DashCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        term,
                        style: DashText.body(
                          context,
                          color: context.dash.textPrimary,
                          weight: FontWeight.w500,
                        ).copyWith(fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(meaning, style: DashText.body(context)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}
