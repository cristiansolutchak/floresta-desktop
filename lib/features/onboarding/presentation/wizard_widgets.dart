import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/dash.dart';

/// Layout of the first-run screens: logo, optional stepper, one white card with
/// a title and subtitle, then Back / primary actions under the card.
class WizardFrame extends StatefulWidget {
  const WizardFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.stepper,
    this.onBack,
    this.primary,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final WizardStepper? stepper;

  /// Null hides Back.
  final VoidCallback? onBack;
  final Widget? primary;

  /// Card width of the setup screens.
  static const cardWidth = 590.0;

  @override
  State<WizardFrame> createState() => _WizardFrameState();
}

class _WizardFrameState extends State<WizardFrame> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Scrollbar(
          controller: _scroll,
          child: LayoutBuilder(
            // Centred on both axes in the space the window gives the flow:
            // the column is at most [WizardFrame.cardWidth] wide and, when it
            // is shorter than the window, sits in the middle instead of
            // hugging the top (which made short steps look off-centre). Taller
            // steps scroll. One frame for every step, so they all line up.
            builder: (context, viewport) => SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (viewport.maxHeight - 80).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: WizardFrame.cardWidth,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Logo(),
                        const SizedBox(height: 24),
                        if (widget.stepper case final s?) ...[
                          s,
                          const SizedBox(height: 16),
                        ],
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            border: Border.all(color: colors.border),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    widget.title,
                                    style: context.text.headlineSmall,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  widget.subtitle,
                                  style: context.text.bodyMedium?.copyWith(
                                    color: colors.muted,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                widget.child,
                              ],
                            ),
                          ),
                        ),
                        if (widget.onBack != null ||
                            widget.primary != null) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              if (widget.onBack case final back?)
                                FilledButton.tonal(
                                  onPressed: back,
                                  child: const Text('Back'),
                                ),
                              const Spacer(),
                              ?widget.primary,
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    // The brand logo, as in the sidebar.
    // Centred over the card, on the flow's axis.
    return Center(
      child: Semantics(
        label: 'Floresta',
        excludeSemantics: true,
        child: SvgPicture.asset(
          DashIcons.logo,
          height: 28,
          colorFilter: ColorFilter.mode(
            Theme.of(context).colorScheme.onSurface,
            BlendMode.srcIn,
          ),
        ),
      ),
    );
  }
}

/// Step indicator. Done steps (and the line after them) are green with a
/// check, the current step has the accent and a dot, steps not reached yet
/// are grey. [current] is the step being edited, so it reflects real
/// progress: a step only turns green once the user moved past it.
class WizardStepper extends StatelessWidget {
  const WizardStepper({super.key, required this.steps, required this.current});

  final List<String> steps;

  /// Index of the current step; [steps.length] means all done.
  final int current;

  static const _box = 24.0;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final done = context.colors.success;
    final grey = context.colors.border;
    final muted = context.colors.muted;
    Widget line(Color color) =>
        Expanded(child: Container(height: 2, color: color));
    return Semantics(
      label:
          'Step ${current + 1 > steps.length ? steps.length : current + 1} '
          'of ${steps.length}: '
          '${current < steps.length ? steps[current] : 'review'}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Column(
                children: [
                  SizedBox(
                    height: _box,
                    child: Row(
                      children: [
                        // The halves of the line to the neighbouring steps:
                        // green once the step before is done.
                        line(
                          i == 0
                              ? Colors.transparent
                              : i - 1 < current
                              ? done
                              : grey,
                        ),
                        _StepBox(
                          size: _box,
                          state: i < current
                              ? _StepState.done
                              : i == current
                              ? _StepState.current
                              : _StepState.future,
                          accent: accent,
                          done: done,
                          grey: grey,
                        ),
                        line(
                          i == steps.length - 1
                              ? Colors.transparent
                              : i < current
                              ? done
                              : grey,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    steps[i],
                    textAlign: TextAlign.center,
                    style: context.text.bodySmall?.copyWith(
                      color: i == current
                          ? accent
                          : i < current
                          ? done
                          : muted,
                      fontWeight: i == current ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum _StepState { done, current, future }

class _StepBox extends StatelessWidget {
  const _StepBox({
    required this.size,
    required this.state,
    required this.accent,
    required this.done,
    required this.grey,
  });

  final double size;
  final _StepState state;
  final Color accent;
  final Color done;
  final Color grey;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.done => done,
      _StepState.current => accent,
      _StepState.future => grey,
    };
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: state == _StepState.done ? done : null,
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: switch (state) {
        _StepState.done => Icon(
          Icons.check,
          size: 16,
          color: Theme.of(context).colorScheme.surface,
        ),
        _ => Center(
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      },
    );
  }
}

enum OptionControl { radio, checkbox, toggle }

/// A selectable option card (network, fast-start option, service). The
/// selected card gets the accent border and a tinted background.
/// [onChanged] null means read-only (shown, not editable).
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.control,
    this.onChanged,
    this.icon,
    this.trailingNote,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final OptionControl control;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  /// Short grey text after the title, e.g. "(Connect Wallets)".
  final String? trailingNote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.colors;
    final enabled = onChanged != null;
    final controlWidget = switch (control) {
      OptionControl.radio => Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: selected ? scheme.primary : colors.muted,
      ),
      OptionControl.checkbox => Icon(
        selected ? Icons.check_box : Icons.check_box_outline_blank,
        size: 18,
        color: selected ? scheme.primary : colors.muted,
      ),
      // A disabled switch reads as "off"; a fixed setting says so in words.
      OptionControl.toggle when !enabled => Text(
        selected ? 'Always on' : 'Unavailable',
        style: context.text.labelMedium?.copyWith(
          color: selected ? scheme.primary : colors.muted,
        ),
      ),
      OptionControl.toggle => Switch(value: selected, onChanged: onChanged),
    };
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          if (control != OptionControl.toggle) ...[
            controlWidget,
            const SizedBox(width: 14),
          ],
          if (icon case final i?) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(i, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: title,
                    style: context.text.titleSmall?.copyWith(
                      color: enabled || selected ? null : colors.muted,
                    ),
                    children: [
                      if (trailingNote case final n?)
                        TextSpan(
                          text: ' $n',
                          style: TextStyle(
                            color: colors.muted,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: context.text.bodySmall),
              ],
            ),
          ),
          if (control == OptionControl.toggle) ...[
            const SizedBox(width: 12),
            controlWidget,
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        selected: selected,
        enabled: enabled,
        child: Material(
          color: selected
              ? scheme.primary.withValues(alpha: 0.04)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: selected ? scheme.primary : colors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: control == OptionControl.toggle || !enabled
              ? body
              : InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => onChanged!(
                    control == OptionControl.radio ? true : !selected,
                  ),
                  child: body,
                ),
        ),
      ),
    );
  }
}
