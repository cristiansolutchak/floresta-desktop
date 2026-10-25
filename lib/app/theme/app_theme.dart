import 'package:flutter/material.dart';

import 'dash_tokens.dart';

/// Semantic colors that Material's ColorScheme has no slot for.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.sidebar,
    required this.border,
    required this.muted,
    required this.success,
    required this.warning,
    required this.danger,
    required this.neutral,
  });

  final Color sidebar;
  final Color border;
  final Color muted;
  final Color success;
  final Color warning;
  final Color danger;
  final Color neutral;

  static const light = AppColors(
    sidebar: Color(0xFFF1F1ED),
    border: Color(0xFFE2E2DC),
    muted: Color(0xFF666B65),
    success: Color(0xFF2B7A4B),
    warning: Color(0xFFA86A12),
    danger: Color(0xFFB42318),
    neutral: Color(0xFF8A8F88),
  );

  static const dark = AppColors(
    sidebar: Color(0xFF151816),
    border: Color(0xFF2A2F2B),
    muted: Color(0xFF9BA29B),
    success: Color(0xFF63C08A),
    warning: Color(0xFFE0A84A),
    danger: Color(0xFFF07B6E),
    neutral: Color(0xFF7D847E),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      border: Color.lerp(border, other.border, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

abstract final class AppTheme {
  static const _accentLight = Color(0xFF2D6A4F);
  static const _accentDark = Color(0xFF74C29A);

  /// Space Grotesk (SIL OFL 1.1, `assets/fonts/Space_Grotesk/OFL.txt`):
  /// the free design FK Grotesk grew from. FK Grotesk is what Figma uses
  /// and needs a paid licence (DS-03).
  static const fontFamily = 'SpaceGrotesk';

  static ThemeData light() => _build(
    brightness: Brightness.light,
    accent: _accentLight,
    background: const Color(0xFFF8F8F6),
    surface: Colors.white,
    onSurface: const Color(0xFF1A1C1A),
    colors: AppColors.light,
    dash: DashTokens.light,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    accent: _accentDark,
    background: const Color(0xFF101211),
    surface: const Color(0xFF181B19),
    onSurface: const Color(0xFFE7E9E6),
    colors: AppColors.dark,
    dash: DashTokens.dark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color accent,
    required Color background,
    required Color surface,
    required Color onSurface,
    required AppColors colors,
    required DashTokens dash,
  }) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          surface: surface,
          onSurface: onSurface,
          outline: colors.border,
          outlineVariant: colors.border,
          error: colors.danger,
        );
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: AppTheme.fontFamily,
      colorScheme: scheme,
      brightness: brightness,
    );
    final text = base.textTheme.apply(
      bodyColor: onSurface,
      displayColor: onSurface,
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      extensions: [colors, dash],
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(color: colors.border, space: 1),
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 13.5, height: 1.45),
        bodySmall: text.bodySmall?.copyWith(color: colors.muted, height: 1.4),
        labelSmall: text.labelSmall?.copyWith(
          color: colors.muted,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          side: BorderSide(color: colors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
  }
}
