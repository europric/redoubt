import 'dart:typed_data';

import 'package:redoubt/core/bip39/bip39.dart';

import 'mnemonic.dart';

/// The fakeable boundary over BIP-39 mnemonic generation and validation.
///
/// **Seam decision (Phase 4, documented deliberately)**: this feature does
/// NOT define a parallel `SeedRepository` domain interface alongside this
/// service. Persistence already has a fakeable boundary —
/// `core/security`'s `SecureSeedRepository` / `AuthenticatedSeedRepository`
/// (built in Phase 3) — and this feature's controllers depend on that
/// interface directly. Adding a second `lib/features/seed/domain/
/// seed_repository.dart` that simply re-exports or delegates to the exact
/// same three methods would be an indirection layer with no behavior
/// difference, so it was deliberately not added.
abstract interface class MnemonicService {
  /// Generates a cryptographically random 24-word BIP-39 mnemonic
  /// (256 bits of entropy) — the locked generation size for this app
  /// (`seed-lifecycle` spec's "Generate BIP-39 Mnemonic" requirement).
  Mnemonic generate();

  /// Whether [phrase] is a valid BIP-39 mnemonic: a standard word count
  /// (12/15/18/21/24), every word present in the wordlist, and a correct
  /// checksum (`seed-lifecycle` spec's "Import Existing Mnemonic With
  /// Validation" requirement).
  bool isValid(String phrase);

  /// Converts an already-[isValid] phrase into its [Mnemonic]
  /// representation (words + entropy hex). Callers MUST validate first —
  /// behavior for an invalid phrase is to throw.
  Mnemonic fromPhrase(String phrase);

  /// Converts raw BIP-39 [entropy] bytes back into their word-list
  /// representation — the reveal-seed flow's use (`ethereum-account` spec's
  /// "Mnemonic still requires a separate gated flow" scenario): the vault
  /// only ever stores entropy, never words, so revealing the mnemonic to
  /// the user means re-deriving the word list from the decrypted entropy.
  /// [entropy] MUST be a valid BIP-39 entropy length (16/20/24/28/32
  /// bytes) — behavior for any other length is to throw.
  ///
  /// [language] selects which wordlist to re-encode [entropy] against —
  /// REQUIRED, never defaulted (bip39-nfkd-normalization design.md D5): this
  /// is the one direction that cannot infer the answer, so a default here
  /// would silently re-encode a non-English vault's entropy as English —
  /// the exact fund-affecting bug this change exists to prevent.
  Mnemonic fromEntropy(Uint8List entropy, {required MnemonicLanguage language});
}
