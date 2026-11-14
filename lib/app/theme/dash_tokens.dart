import 'package:flutter/material.dart';

/// Colours of the dashboard design. The palette is Untitled UI's (for
/// example Success/600 #079455); the dark values follow the app's dark
/// theme.
@immutable
class DashTokens extends ThemeExtension<DashTokens> {
  const DashTokens({
    required this.page,
    required this.surface,
    required this.subtle,
    required this.border,
    required this.borderStrong,
    required this.track,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.primaryButton,
    required this.onPrimaryButton,
    required this.secondaryButton,
    required this.sidebarActive,
    required this.brand,
    required this.warning,
    required this.warningText,
    required this.warningBg,
    required this.warningBorder,
    required this.info,
    required this.infoBg,
    required this.infoBorder,
    required this.success,
    required this.successDot,
    required this.successBg,
    required this.successBorder,
    required this.danger,
    required this.dangerBg,
    required this.dangerBorder,
    this.codeBg = const Color(0xFF0A0A0A),
    this.codeText = const Color(0xFFE4E7EC),
    this.codeMuted = const Color(0xFF85888E),
    this.codeKey = const Color(0xFF84CAFF),
    this.codeString = const Color(0xFF75E0A7),
    this.codeNumber = const Color(0xFFFDB022),
    this.codeError = const Color(0xFFFDA29B),
  });

  final Color page;
  final Color surface;

  /// Inner boxes: inbound/outbound tiles, service rows, help boxes.
  final Color subtle;
  final Color border;

  /// Outline buttons.
  final Color borderStrong;

  /// Empty part of progress bars.
  final Color track;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color primaryButton;
  final Color onPrimaryButton;
  final Color secondaryButton;
  final Color sidebarActive;

  /// Active navigation item text/icon.
  final Color brand;

  /// Sync progress bar, "Syncing" tag text, behind counts.
  final Color warning;
  final Color warningText;
  final Color warningBg;
  final Color warningBorder;
  final Color info;
  final Color infoBg;
  final Color infoBorder;
  final Color success;
  final Color successDot;
  final Color successBg;
  final Color successBorder;
  final Color danger;
  final Color dangerBg;
  final Color dangerBorder;

  /// The dark code panels (RPC/Electrum response, logs) look the same in both
  /// themes: near-black, light text, blue keys and tags, green
  /// strings, orange numbers.
  final Color codeBg;
  final Color codeText;
  final Color codeMuted;
  final Color codeKey;
  final Color codeString;
  final Color codeNumber;
  final Color codeError;

  static const light = DashTokens(
    page: Color(0xFFF8FAFC),
    surface: Color(0xFFFFFFFF),
    subtle: Color(0xFFF8FAFC),
    border: Color(0xFFE8EDF3),
    borderStrong: Color(0xFFC3C9D1), // Border/border-primary
    track: Color(0xFFF2F5F9),
    textPrimary: Color(0xFF000000), // Text/text-primary
    textSecondary: Color(0xFF626D7C), // Text/text-secondary
    textMuted: Color(0xFFA2ABB8), // Text/text-primary-muted
    primaryButton: Color(0xFF000000),
    onPrimaryButton: Color(0xFFFFFFFF),
    secondaryButton: Color(0xFFE2E5EB), // Surface/surface-secondary-disabled
    sidebarActive: Color(0xFFF1F4F8),
    brand: Color(0xFF266F52),
    warning: Color(0xFFF79009), // Warning/500
    // Warning/700: Warning/600 (#DC6803) is 3.4:1 on white, below
    // WCAG's 4.5:1 for text; checked by the accessibility test.
    warningText: Color(0xFFB54708),
    warningBg: Color(0xFFFFFCF5), // Warning/25
    warningBorder: Color(0xFFF2EDE0),
    info: Color(0xFF175CD3), // Blue/700
    infoBg: Color(0xFFEFF8FF), // Blue/50
    infoBorder: Color(0xFFB2DDFF), // Blue/200
    success: Color(0xFF067647), // Success/700
    successDot: Color(0xFF17B26A), // Success/500
    successBg: Color(0xFFECFDF3), // Success/50
    successBorder: Color(0xFF75E0A7), // Success/300
    danger: Color(0xFFB42318), // Error/700
    dangerBg: Color(0xFFFEF3F2), // Error/50
    dangerBorder: Color(0xFFFECDCA), // Error/200
  );

  static const dark = DashTokens(
    page: Color(0xFF101211),
    surface: Color(0xFF181B19),
    subtle: Color(0xFF1E2220),
    border: Color(0xFF2A2F2B),
    borderStrong: Color(0xFF3A403C),
    track: Color(0xFF262B28),
    textPrimary: Color(0xFFF2F4F2),
    textSecondary: Color(0xFFA3AAA4),
    textMuted: Color(0xFF6E756F),
    primaryButton: Color(0xFFF2F4F2),
    onPrimaryButton: Color(0xFF101211),
    secondaryButton: Color(0xFF2A2F2B),
    sidebarActive: Color(0xFF1E2421),
    brand: Color(0xFF74C29A),
    warning: Color(0xFFFDB022),
    warningText: Color(0xFFFDB022),
    warningBg: Color(0xFF221C11),
    warningBorder: Color(0xFF4A3B1C),
    info: Color(0xFF84CAFF),
    infoBg: Color(0xFF13202E),
    infoBorder: Color(0xFF1E3A5C),
    success: Color(0xFF75E0A7),
    successDot: Color(0xFF47CD89),
    successBg: Color(0xFF10241A),
    successBorder: Color(0xFF1F4A33),
    danger: Color(0xFFFDA29B),
    dangerBg: Color(0xFF2A1513),
    dangerBorder: Color(0xFF5A2620),
  );

  @override
  DashTokens copyWith() => this;

  @override
  DashTokens lerp(DashTokens? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

extension DashTokensContext on BuildContext {
  DashTokens get dash => Theme.of(this).extension<DashTokens>()!;
}
