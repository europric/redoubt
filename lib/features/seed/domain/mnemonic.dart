import 'dart:typed_data';

import 'package:redoubt/core/bip39/bip39.dart';

/// A BIP-39 mnemonic phrase paired with the entropy it encodes.
///
/// [words] is what a human reads, re-enters, and verifies; [entropy] is
/// what `core/security`'s `SecureSeedRepository` persists (see
/// `secure-seed-storage`'s "Signing Keys Are Derived Transiently, Never
/// Persisted" requirement — a mnemonic string is never written to storage
/// directly, only its entropy).
///
/// **`Uint8List` migration (vault-secure-storage-redesign PR1)**: [entropy]
/// is raw bytes, never a hex `String` (`seed-exposure-protection`'s "End-
/// To-End Zeroizable Secret Handling" requirement). [words] deliberately
/// stays `List<String>` — BIP-39 words must render/compare, a
/// `TextEditingController` holds a `String`, and Dart strings cannot be
/// zeroized; mitigation for the word list is lifetime, not erasure.
///
/// **`language` field (bip39-nfkd-normalization PR1/3, design.md D4)**:
/// REQUIRED, never defaulted. [words] are already language-specific, so a
/// `Mnemonic` without a language was always an internally incomplete value
/// — you cannot round-trip it through `fromEntropy` without external
/// knowledge it doesn't carry. A field on the type (rather than a parallel
/// parameter threaded alongside it through commit/sign/reveal) makes the
/// pairing unforgeable by construction: it cannot be silently dropped at
/// one call site the way a scattered parameter could.
///
/// **`toString()` deliberately does not print [language]** — locale is
/// stored *encrypted* (Phase 2's framed sealed plaintext) precisely so it
/// does not leak at rest; printing it here would leak it to logs instead,
/// contradicting that same intent (see `test/core/security/
/// no_seed_in_logs_test.dart`).
class Mnemonic {
  const Mnemonic({
    required this.words,
    required this.entropy,
    required this.language,
  });

  final List<String> words;
  final Uint8List entropy;

  /// The BIP-39 wordlist this mnemonic's [words] belong to — required so
  /// every derivation site can re-encode [entropy] against the correct
  /// wordlist instead of silently defaulting to English.
  final MnemonicLanguage language;

  /// The mnemonic phrase as a single space-separated string.
  String get phrase => words.join(' ');

  /// Zero-fills [entropy] in place. Callers MUST call this once the
  /// mnemonic is no longer needed (seed-commit success, or reveal-seed view
  /// close — `seed-exposure-protection`'s "Mnemonic buffer zeroized after
  /// use" scenario).
  void zeroize() => entropy.fillRange(0, entropy.length, 0);

  @override
  String toString() => 'Mnemonic(${words.length} words)';
}
