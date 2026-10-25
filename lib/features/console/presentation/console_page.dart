import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart' hide State;

import '../../../app/theme/dash_tokens.dart';
import '../../../core/errors/failure.dart';
import '../../../core/security/sensitive_data.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/dash.dart';
import '../../node/presentation/node_controller.dart';
import '../../settings/presentation/settings_controller.dart';
import '../data/console_repositories.dart';
import '../domain/console_repository.dart';
import '../domain/console_template.dart';

final rpcConsoleRepositoryProvider = Provider<ConsoleRepository>(
  (ref) => RpcConsoleRepository(ref.watch(rpcClientProvider)),
);

final electrumConsoleRepositoryProvider = Provider<ConsoleRepository>((ref) {
  final network = ref.watch(
    settingsControllerProvider.select((s) => s.network),
  );
  return ElectrumConsoleRepository(
    host: '127.0.0.1',
    port: network.electrumPort,
  );
});

/// Figma "RPC Call Console" (1:17085) and "Electrum Console" (1:16524):
/// templates, a request editor and the node's raw answer.
class ConsolePage extends ConsumerStatefulWidget {
  const ConsolePage(this.kind, {super.key});

  final ConsoleKind kind;

  @override
  ConsumerState<ConsolePage> createState() => _ConsolePageState();
}

sealed class _Answer {
  const _Answer(this.elapsed);
  final Duration elapsed;
}

class _Result extends _Answer {
  const _Result(this.json, super.elapsed);
  final String json;
}

class _Error extends _Answer {
  const _Error(this.failure, super.elapsed);
  final Failure failure;
}

class _ConsolePageState extends ConsumerState<ConsolePage> {
  final _method = TextEditingController();
  final _params = TextEditingController();
  var _tab = 0;
  ConsoleTemplate? _selected;
  _Answer? _answer;
  var _running = false;

  bool get _rpc => widget.kind == ConsoleKind.rpc;

  List<ConsoleTemplate> get _templates => _rpc
      ? rpcTemplates.where((t) => t.category == rpcCategories[_tab]).toList()
      : electrumTemplates;

  @override
  void initState() {
    super.initState();
    _pick(_templates.first);
  }

  @override
  void dispose() {
    _method.dispose();
    _params.dispose();
    super.dispose();
  }

  void _pick(ConsoleTemplate t) {
    final chain = ref.read(nodeControllerProvider).chain;
    final params = t.params(
      ConsoleContext(
        tipHeight: chain?.validatedHeight,
        bestBlockHash: chain?.bestBlockHash,
      ),
    );
    setState(() {
      _selected = t;
      _method.text = t.method;
      _params.text = params.isEmpty ? '[]' : prettyJson(params);
    });
  }

  Future<void> _run() async {
    final method = _method.text.trim();
    if (method.isEmpty) {
      showFailure(context, const ValidationFailure('Enter a method name.'));
      return;
    }
    // Never send key material anywhere (bitcoin-security rules).
    if (SensitiveData.detectSecret('$method ${_params.text}') case final why?) {
      _params.clear();
      // Shown in the response panel, not only a snackbar: it must be seen.
      setState(
        () =>
            _answer = _Error(SecretMaterialRejectedFailure(why), Duration.zero),
      );
      return;
    }
    final params = parseParams(_params.text);
    if (params case Left(value: final error)) {
      setState(() => _answer = _Error(ValidationFailure(error), Duration.zero));
      return;
    }
    if (changesState(widget.kind, method)) {
      final ok = await confirm(
        context,
        title: 'Run $method?',
        message:
            '$method changes what the node does (for example stopping it, '
            'connecting peers or broadcasting). The app will not undo it.',
        confirmLabel: 'Run',
      );
      if (!ok || !mounted) return;
    }
    final repo = ref.read(
      _rpc ? rpcConsoleRepositoryProvider : electrumConsoleRepositoryProvider,
    );
    setState(() => _running = true);
    final watch = Stopwatch()..start();
    final result = await repo.call(method, params.getOrElse((_) => const []));
    if (!mounted) return;
    setState(() {
      _running = false;
      _answer = result.match(
        (f) => _Error(f, watch.elapsed),
        (r) => _Result(prettyJson(r), watch.elapsed),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(
      _rpc ? rpcConsoleRepositoryProvider : electrumConsoleRepositoryProvider,
    );
    return DashPage(
      children: [
        DashPageHeader(
          asset: _rpc ? DashIcons.rpcConsole : DashIcons.electrum,
          title: _rpc ? 'RPC Call Console' : 'Electrum Console',
          tag: _rpc ? const DashTag('Advanced') : null,
          subtitle: repo.endpoint,
          help: _rpc
              ? 'Some RPCs can modify node state (e.g. stop, addnode). '
                    'Ensure you know what a command does before running it. '
                    'Start with read-only commands.'
              : 'Requests go to the Electrum server of your own node. The '
                    'templates only read data; broadcasting a transaction '
                    'asks first.',
        ),
        const SizedBox(height: 24),
        if (_rpc) ...[
          DashTabs(
            labels: rpcCategories,
            selected: _tab,
            onSelected: (i) {
              setState(() => _tab = i);
              _pick(_templates.first);
            },
          ),
          const SizedBox(height: 16),
        ],
        LayoutBuilder(
          builder: (context, c) {
            final panels = [
              _templatesPanel(context),
              _requestPanel(context),
              _responsePanel(context),
            ];
            if (c.maxWidth < 820) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in panels) ...[
                    SizedBox(height: 520, child: p),
                    const SizedBox(height: 8),
                  ],
                ],
              );
            }
            return SizedBox(
              height: 567,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 272, child: panels[0]),
                  const SizedBox(width: 8),
                  Expanded(flex: 344, child: panels[1]),
                  const SizedBox(width: 8),
                  Expanded(flex: 320, child: panels[2]),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _panelTitle(BuildContext context, String title, String? subtitle) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: DashText.cardTitle(context).copyWith(fontSize: 16),
            ),
          ),
          if (subtitle != null) Text(subtitle, style: DashText.body(context)),
        ],
      );

  Widget _templatesPanel(BuildContext context) {
    final t = context.dash;
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelTitle(
            context,
            'Templates',
            'Templates are safe starting points.',
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                for (final tpl in _templates)
                  Material(
                    color: tpl == _selected ? t.subtle : Colors.transparent,
                    child: InkWell(
                      onTap: () => _pick(tpl),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tpl.method,
                              style: monoStyle(context, size: 13).copyWith(
                                color: tpl == _selected
                                    ? t.brand
                                    : t.textPrimary,
                              ),
                            ),
                            Text(
                              tpl.description,
                              style: DashText.small(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _requestPanel(BuildContext context) {
    final t = context.dash;
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: t.surface,
      contentPadding: const EdgeInsets.all(12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(2),
        borderSide: BorderSide(color: t.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(2),
        borderSide: BorderSide(color: t.textPrimary),
      ),
    );
    final code = monoStyle(context, size: 13).copyWith(color: t.textPrimary);
    return DashCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelTitle(context, 'Request', 'Params are a JSON array, in order.'),
          const SizedBox(height: 16),
          Text(
            'Method',
            style: DashText.body(
              context,
              color: t.textPrimary,
              weight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _method,
            style: code,
            decoration: deco(_rpc ? 'getblockchaininfo' : 'server.version'),
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 16),
          Text(
            'Params (JSON)',
            style: DashText.body(
              context,
              color: t.textPrimary,
              weight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: _params,
              style: code,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: deco('[]'),
            ),
          ),
          const SizedBox(height: 16),
          DashButton(
            _running ? 'Running…' : 'Run Call',
            style: DashButtonStyle.primary,
            icon: Icons.play_arrow_outlined,
            expand: true,
            onPressed: _running ? null : _run,
          ),
        ],
      ),
    );
  }

  Widget _responsePanel(BuildContext context) {
    final t = context.dash;
    final answer = _answer;
    final text = switch (answer) {
      _Result(:final json) => json,
      _Error(:final failure) => switch (failure) {
        RpcErrorFailure(:final code, :final message) => prettyJson({
          'error': {'code': code, 'message': message},
        }),
        ElectrumServerErrorFailure(:final code, :final message) => prettyJson({
          'error': {'code': code, 'message': message},
        }),
        final f => [f.title, f.message, ?f.recovery].join('\n'),
      },
      null => null,
    };
    return DashCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Row(
              children: [
                Expanded(child: _panelTitle(context, 'Response', null)),
                DashButton(
                  'Copy Response',
                  height: 32,
                  asset: DashIcons.copy,
                  onPressed: text == null
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) {
                            showMessage(context, 'Response copied');
                          }
                        },
                ),
              ],
            ),
          ),
          Expanded(
            child: DashCodeBox(
              child: SingleChildScrollView(
                child: switch (answer) {
                  null => Text(
                    'Run a call to see the node\'s answer here.',
                    style: dashCode(context, color: t.codeMuted),
                  ),
                  _Result() => SelectableText.rich(
                    highlightJson(context, text!),
                  ),
                  _Error() => SelectableText(
                    text!,
                    style: dashCode(context, color: t.codeError),
                  ),
                },
              ),
            ),
          ),
          if (answer != null && answer.elapsed > Duration.zero)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '${answer is _Result ? 'Answered' : 'Failed'} in '
                '${answer.elapsed.inMilliseconds} ms',
                style: DashText.small(context),
              ),
            ),
        ],
      ),
    );
  }
}
