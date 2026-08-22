/// `dart:ui`-only const mirror of `design/redoubt-brand/tokens.json`'s
/// `color` and `typography.scale` sections (design.md D1/D5). Names stay
/// verbatim from the JSON source — interpretation of these raw values into
/// a Material `ColorScheme`/`TextTheme` lives in `AppTheme`
/// (`app_theme.dart`), never here. That split is deliberate (design.md D1):
/// `tokens.json`'s naming is inverted vs. visual weight (`borderStrong` is
/// LIGHTER than `border`), so a literal mirror plus a separate
/// interpretation layer keeps both facts visible instead of silently
/// "fixing" the source names.
///
/// Machine-verified 1:1 against `tokens.json` by
/// `test/core/presentation/redoubt_tokens_test.dart`, which parses the JSON
/// file directly rather than hardcoding expected values a second time.
library;

import 'dart:ui' show Color, FontWeight;

/// One `typography.scale` tier's raw values, mirrored value-for-value from
/// `tokens.json`. `letterSpacing` is pre-converted from the JSON's `em`
/// string (e.g. `"-0.01em"`) to absolute logical pixels
/// (`emValue * size`), since Flutter's `TextStyle.letterSpacing` is
/// px-based, not em-based.
class RedoubtScaleTier {
  const RedoubtScaleTier({
    required this.size,
    required this.lineHeight,
    required this.weight,
    this.letterSpacing = 0,
  });

  final double size;
  final double lineHeight;
  final FontWeight weight;
  final double letterSpacing;
}

/// `dart:ui`-only const mirror of `tokens.json`'s `color` and
/// `typography.scale` sections. Zero `package:flutter` imports (D1) — this
/// file, unlike `app_theme.dart`, may be imported from anywhere R2 permits
/// `core/**` to be imported from.
abstract final class RedoubtTokens {
  // color.* — verbatim from tokens.json; see AppTheme for ColorScheme
  // slot interpretation (design.md D1).
  static const wall = Color(0xFF16181A);
  static const vaultAccent = Color(0xFFC8102E);
  static const courtyard = Color(0xFFFBFAF8);
  static const secondary = Color(0xFF7B7873);

  /// `color.lightTheme.border` — the canonical 1px hairline.
  static const lightBorder = Color(0xFFDCD8D1);

  /// `color.lightTheme.borderStrong` — despite the name, this is LIGHTER
  /// than [lightBorder] in `tokens.json` (D1's naming-inversion note);
  /// mirrored verbatim, interpreted by visual weight in `AppTheme`.
  static const lightBorderStrong = Color(0xFFE6E2DB);

  // typography.display.family / typography.mono.family
  static const displayFamily = 'Archivo';
  static const monoFamily = 'JetBrains Mono';

  // typography.scale — the five tiers actually referenced by AppTheme's
  // TextTheme mapping (design.md D5).
  static const displayLg = RedoubtScaleTier(
    size: 40,
    lineHeight: 44,
    weight: FontWeight.w800,
    letterSpacing: -0.4, // -0.01em * 40
  );
  static const displaySm = RedoubtScaleTier(
    size: 22,
    lineHeight: 28,
    weight: FontWeight.w700,
  );
  static const body = RedoubtScaleTier(
    size: 15,
    lineHeight: 22,
    weight: FontWeight.w500,
  );
  static const data = RedoubtScaleTier(
    size: 14,
    lineHeight: 20,
    weight: FontWeight.w400,
  );
  static const label = RedoubtScaleTier(
    size: 10,
    lineHeight: 14,
    weight: FontWeight.w400,
    letterSpacing: 2.0, // 0.2em * 10
  );
}
