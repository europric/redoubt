/// Redoubt's single global light `ThemeData` — the sole `package:google_fonts`
/// import site (R5 gateway, design.md D10). Composes [RedoubtTokens] into a
/// Material `ColorScheme`, 15-slot `TextTheme`, and flat zero-radius
/// component themes. No screen may construct a competing `ThemeData`
/// (`brand-theme` spec's "Global Light Theme Applied Once, From Tokens").
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'redoubt_tokens.dart';

/// `title{Medium,Small}` interpolates size 15 + weight 700 — both declared
/// in `tokens.json`'s scale, but not as a named tier of their own
/// (design.md D5).
const _interpolatedTitle = RedoubtScaleTier(
  size: 15,
  lineHeight: 22,
  weight: FontWeight.w700,
);

/// `labelLarge` (button text) comes from `components.md`'s button spec, not
/// `tokens.json`'s `typography.scale` — "14px / weight 700 / letter-spacing
/// 0.08em" (design.md D5). `0.08em * 14 = 1.12`.
const _buttonLabelSize = 14.0;
const _buttonLabelWeight = FontWeight.w700;
const _buttonLabelLetterSpacing = 1.12;

abstract final class AppTheme {
  /// Lazily built once, cached (design.md D3) — a getter that rebuilt
  /// `ThemeData` on every access would be wasted work, since nothing else
  /// ever flips [GoogleFonts.config.allowRuntimeFetching] back on.
  static final ThemeData light = _buildLight();

  static ThemeData _buildLight() {
    // D3 / security: this MUST be the first statement of the builder, not
    // main() — widget tests never call main(), so main()-only placement
    // would leave every test building themes with runtime fetching still
    // enabled. The air-gap guarantee is this flag ALONE; asset resolution
    // below only decides brand-font-vs-Roboto rendering, a cosmetic
    // fallback, never a network one.
    GoogleFonts.config.allowRuntimeFetching = false;

    const colorScheme = ColorScheme.light(
      primary: RedoubtTokens.wall,
      onPrimary: RedoubtTokens.courtyard,
      secondary: RedoubtTokens.secondary,
      onSecondary: RedoubtTokens.courtyard,
      error: RedoubtTokens.vaultAccent,
      onError: RedoubtTokens.courtyard,
      // Non-error accent affordance ("one vault element per view" —
      // components.md); deliberately the SAME hex as error, mapped to a
      // different ColorScheme slot for a different semantic use
      // (design.md D1/D6).
      tertiary: RedoubtTokens.vaultAccent,
      onTertiary: RedoubtTokens.courtyard,
      surface: RedoubtTokens.courtyard,
      onSurface: RedoubtTokens.wall,
      onSurfaceVariant: RedoubtTokens.secondary,
      outline: RedoubtTokens.lightBorder,
      outlineVariant: RedoubtTokens.lightBorderStrong,
    );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: RedoubtTokens.courtyard,
      textTheme: _buildTextTheme(),
      cardTheme: _flatCardTheme(colorScheme),
      filledButtonTheme: _flatFilledButtonTheme(),
      outlinedButtonTheme: _flatOutlinedButtonTheme(),
      inputDecorationTheme: _flatInputDecorationTheme(colorScheme),
      dialogTheme: _flatDialogTheme(),
    );
  }

  static TextStyle _display(RedoubtScaleTier tier) => GoogleFonts.archivo(
    fontSize: tier.size,
    fontWeight: tier.weight,
    letterSpacing: tier.letterSpacing,
    height: tier.lineHeight / tier.size,
  );

  static TextStyle _mono(RedoubtScaleTier tier) => GoogleFonts.jetBrainsMono(
    fontSize: tier.size,
    fontWeight: tier.weight,
    letterSpacing: tier.letterSpacing,
    height: tier.lineHeight / tier.size,
  );

  /// All 15 Material `TextTheme` slots mapped explicitly (design.md D5) —
  /// none left to fall back to the Material default (Roboto).
  static TextTheme _buildTextTheme() {
    final displayLg = _display(RedoubtTokens.displayLg);
    final displaySm = _display(RedoubtTokens.displaySm);
    final title = _display(_interpolatedTitle);
    // bodyMedium -> body is load-bearing: it is what a bare `Text` resolves
    // to (design.md D5).
    final body = _display(RedoubtTokens.body);
    final data = _mono(RedoubtTokens.data);
    final label = _mono(RedoubtTokens.label);
    final buttonLabel = GoogleFonts.archivo(
      fontSize: _buttonLabelSize,
      fontWeight: _buttonLabelWeight,
      letterSpacing: _buttonLabelLetterSpacing,
    );

    return TextTheme(
      displayLarge: displayLg,
      displayMedium: displayLg,
      displaySmall: displayLg,
      headlineLarge: displaySm,
      headlineMedium: displaySm,
      headlineSmall: displaySm,
      titleLarge: displaySm,
      titleMedium: title,
      titleSmall: title,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: data,
      labelLarge: buttonLabel,
      labelMedium: label,
      labelSmall: label,
    );
  }

  /// Flat rectangle, 1px hairline, no shadow (`components.md`'s "flat
  /// rectangles everywhere" rule) — centralises 3 of the 7 radius sites
  /// design.md D8 found (`account_page.dart` x2, `signature_qr_page.dart`).
  static CardThemeData _flatCardTheme(ColorScheme colorScheme) => CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: colorScheme.outline),
      borderRadius: BorderRadius.zero,
    ),
  );

  static FilledButtonThemeData _flatFilledButtonTheme() =>
      FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const RoundedRectangleBorder()),
      );

  static OutlinedButtonThemeData _flatOutlinedButtonTheme() =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: const RoundedRectangleBorder()),
      );

  static InputDecorationThemeData _flatInputDecorationTheme(
    ColorScheme colorScheme,
  ) => InputDecorationThemeData(
    border: OutlineInputBorder(
      borderSide: BorderSide(color: colorScheme.outline),
      borderRadius: BorderRadius.zero,
    ),
  );

  static DialogThemeData _flatDialogTheme() =>
      const DialogThemeData(elevation: 0, shape: RoundedRectangleBorder());
}
