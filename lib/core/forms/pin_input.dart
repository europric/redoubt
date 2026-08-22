import 'dart:convert';

/// The canonical 6-digit numeric PIN format rule (`^\d{6}$`) plus a
/// confirm-match rule, replacing the copy-pasted `RegExp` previously local
/// to `pin_setup_page.dart` (`spec.md`'s "PinInput Centralizes PIN Format
/// Validation" requirement).
///
/// **Single source of truth**: `pin_entry_page.dart` now consumes this
/// class directly instead of keeping its own copy of the pattern
/// (state-management-rollout closed the drift this deferred — see that
/// file and design.md's "`_pinPattern` deletion is a 4-line mechanical
/// swap" decision). The parity test that used to guard the two copies
/// against drift (`test/core/forms/pin_input_parity_test.dart`) has been
/// retired: with a single shared import, parity is structural and no
/// dedicated test is needed.
///
/// **No `==`/`hashCode`/`toString()` override** — same rule as [Mnemonic]
/// and `AsyncState`: this type carries PIN material, so it must never be
/// transitively value-compared or printed. Constant-time comparison is
/// deliberately NOT used in [matches] — both operands are local values held
/// only for the duration of a form submission, and the actual
/// security-relevant comparison is Argon2id inside `VaultCipher`, not this
/// UI-level format/match check (design.md's "PinInput" decision).
final class PinInput {
  const PinInput(this.value);

  /// The raw, unvalidated PIN text as entered by the user.
  final String value;

  static final RegExp _pinPattern = RegExp(r'^\d{6}$');

  /// Human-readable message for an invalid PIN format.
  static const invalidFormatMessage = 'PIN must be exactly 6 digits.';

  /// Human-readable message for a confirm-PIN mismatch.
  static const mismatchMessage = 'PINs do not match. Please try again.';

  /// Whether [value] matches the canonical 6-digit numeric PIN format.
  bool get isValid => _pinPattern.hasMatch(value);

  /// Whether this PIN's [value] is identical to [confirmation]'s.
  bool matches(PinInput confirmation) => value == confirmation.value;

  /// UTF-8 encodes [value], for handing to a zeroizable `Uint8List`-based
  /// API (e.g. `VaultCommitService.commit`).
  List<int> toBytes() => utf8.encode(value);
}
