import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/dash_tokens.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../settings/data/text_file_writer.dart';
import '../../settings/presentation/diagnostics.dart';
import '../domain/log_category.dart';
import '../domain/node_process_state.dart';
import 'node_controller.dart';

/// Figma "Logs (Active)" (1:17706): daemon output filtered by area, Copy
/// Visible and Export Diagnostics. Lines are already redacted by
/// [LogBuffer] (extended keys).
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final _scroll = ScrollController();
  LogCategory? _filter;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<ParsedLogLine> _parse(List<LogLine> lines) {
    final parsed = parseLogLines(lines.map((l) => l.text));
    return [
      for (var i = 0; i < lines.length; i++)
        // The app's own notes ("Starting florestad…") are about services.
        lines[i].source == LogSource.app
            ? ParsedLogLine(
                text: lines[i].text,
                category: LogCategory.services,
                time: _clock(lines[i].time),
                message: lines[i].text,
              )
            : parsed[i],
    ];
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = t.toLocal();
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  Future<void> _export(List<ParsedLogLine> all) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'floresta-diagnostics-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.txt';
    final location = await getSaveLocation(suggestedName: name);
    if (location == null || !mounted) return;
    final text = [
      'Floresta GUI diagnostics (${now.toIso8601String()})',
      'No wallet data. Extended keys in the log are redacted.',
      '',
      ref.read(diagnosticsReportProvider),
      '',
      'Daemon output (last ${all.length} lines):',
      for (final l in all) l.text,
    ].join('\n');
    final result = await writeTextFile(location.path, text);
    if (!mounted) return;
    result.fold(
      (f) => showFailure(context, f),
      (_) => showMessage(context, 'Diagnostics saved to ${location.path}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.dash;
    final lines = ref.watch(nodeLogsProvider);
    final adopted =
        ref.watch(nodeControllerProvider.select((s) => s.process))
            is ProcessAdopted;
    final all = _parse(lines);
    final visible = _filter == null
        ? all
        : all.where((l) => l.category == _filter).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });

    return DashPage(
      children: [
        DashPageHeader(
          asset: DashIcons.logsNav,
          title: 'System Logs',
          subtitle: 'If something breaks, the answer is usually here.',
          actions: [
            DashButton(
              'Export Diagnostics',
              style: DashButtonStyle.secondary,
              tooltip: 'Save app details and the output below to a text file',
              onPressed: () => _export(all),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DashChip(
              'All',
              selected: _filter == null,
              onTap: () => setState(() => _filter = null),
            ),
            for (final c in LogCategory.values)
              DashChip(
                c.label,
                selected: _filter == c,
                onTap: () => setState(() => _filter = c),
              ),
          ],
        ),
        const SizedBox(height: 16),
        DashCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Daemon output',
                          style: DashText.cardTitle(
                            context,
                          ).copyWith(fontSize: 16),
                        ),
                      ),
                    ),
                    DashButton(
                      'Copy Visible',
                      height: 32,
                      asset: DashIcons.copy,
                      onPressed: visible.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                ClipboardData(
                                  text: visible.map((l) => l.text).join('\n'),
                                ),
                              );
                              if (context.mounted) {
                                showMessage(
                                  context,
                                  'Copied ${visible.length} lines',
                                );
                              }
                            },
                    ),
                  ],
                ),
              ),
              DashCodeBox(
                height: 420,
                child: visible.isEmpty
                    ? Text(
                        lines.isEmpty
                            ? adopted
                                  ? 'This node was started before the app '
                                        'last restarted, so its output goes '
                                        'to debug.log in the data folder.'
                                  : 'No output yet. Output from a node '
                                        'started by this app appears here.'
                            : 'No ${_filter!.label} lines yet.',
                        style: dashCode(context, color: t.codeMuted),
                      )
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          itemCount: visible.length,
                          itemBuilder: (context, i) =>
                              _LogRow(visible[i], tokens: t),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow(this.line, {required this.tokens});
  final ParsedLogLine line;
  final DashTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final message = line.message;
    if (message == null) {
      return Text(line.text, style: dashCode(context, color: t.codeText));
    }
    return Text.rich(
      TextSpan(
        style: dashCode(context),
        children: [
          if (line.time != null)
            TextSpan(
              text: '${line.time}  ',
              style: TextStyle(color: t.codeMuted),
            ),
          TextSpan(
            text: '[${line.category.tag}]  ',
            style: TextStyle(color: t.codeKey),
          ),
          if (line.isProblem)
            TextSpan(
              text: '${line.level} ',
              style: TextStyle(color: t.codeError),
            ),
          TextSpan(
            text: message,
            style: TextStyle(color: line.isProblem ? t.codeError : t.codeText),
          ),
        ],
      ),
    );
  }
}
