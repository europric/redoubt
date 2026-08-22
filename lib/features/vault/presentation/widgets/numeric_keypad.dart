/// Shared on-screen numeric keypad — used by both `pin_setup_page.dart` and
/// `pin_entry_page.dart` (design.md D1: intra-`features/vault` sharing only,
/// never `lib/core/`). Replaces the OS-keyboard `TextField` PIN input
/// (`critical-screen-ux` spec's "PIN Keypad Input With Dot Indicators"
/// requirement): digits-only input is enforced structurally — there is no
/// text field to open an IME on, and no key exists for anything but 0-9 and
/// backspace (design.md D2).
library;

import 'package:flutter/material.dart';

class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
    this.onBiometric,
    this.biometricIcon,
  });

  /// Invoked with the tapped digit (0-9) when [enabled].
  final ValueChanged<int> onDigit;

  /// Invoked when the backspace key is tapped, when [enabled].
  final VoidCallback onBackspace;

  /// When `false`, no key emits either callback.
  final bool enabled;

  /// Optional biometric-retry callback (biometric-unlock-onboarding
  /// design.md D7). `null` (the default) keeps the blank cell blank --
  /// every pre-existing call site (sign/reveal/delete/PIN-setup) is
  /// unaffected structurally, not by convention. Only the `app-unlock-gate`
  /// PIN-fallback screen's keypad ever passes this.
  final VoidCallback? onBiometric;

  /// The icon shown in the blank cell when [onBiometric] is non-null.
  /// Defaults to [Icons.fingerprint] when `null`.
  final IconData? biometricIcon;

  // 4 rows x 3 columns: 1-9, then blank / 0 / backspace. `null` = blank
  // cell, `-1` = backspace, everything else is its own digit.
  static const _keys = [1, 2, 3, 4, 5, 6, 7, 8, 9, null, 0, -1];
  static const _keysPerRow = 3;

  // A plain `Column` of `Row`s, not a `GridView` -- the key count is fixed
  // and never scrolls, and a shrink-wrapped `GridView` is backed by a
  // viewport, which cannot report an intrinsic height (needed by the pages'
  // `SliverFillRemaining`/`IntrinsicHeight`-based "pin to bottom" layout).
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < _keys.length; row += _keysPerRow)
          Row(
            children: [
              for (final key in _keys.skip(row).take(_keysPerRow))
                Expanded(
                  child: AspectRatio(aspectRatio: 1.4, child: _key(key)),
                ),
            ],
          ),
      ],
    );
  }

  Widget _key(int? key) {
    if (key == null) {
      if (onBiometric == null) return const SizedBox.shrink();
      return _KeypadKey(
        onTap: enabled ? onBiometric : null,
        child: Icon(biometricIcon ?? Icons.fingerprint),
      );
    }
    if (key == -1) {
      return _KeypadKey(
        onTap: enabled ? onBackspace : null,
        child: const Icon(Icons.backspace_outlined),
      );
    }
    return _KeypadKey(
      onTap: enabled ? () => onDigit(key) : null,
      child: Text('$key', style: const TextStyle(fontSize: 24)),
    );
  }
}

class _KeypadKey extends StatelessWidget {
  const _KeypadKey({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Center(child: child),
    );
  }
}
