/// Shared BIP-39 seed derivation (entropy -> mnemonic -> 64-byte seed),
/// used by both `account/data/bip32_account_derivation_service.dart` and
/// `signing/data/eth_transaction_signer.dart` — previously duplicated as a
/// private method in each (`_defaultSeedFromEntropy` /
/// `_seedFromEntropy`), and both call sites ran it synchronously on the
/// caller's isolate.
///
/// **Why this now runs in a background isolate**: confirmed via real
/// physical-device testing — even AFTER commit `8aaa646` cut the redundant
/// 3x derivation down to 1x per Account-screen load, the loading spinner's
/// `CircularProgressIndicator` rotation animation still visibly FROZE
/// (stopped ticking entirely, not merely slowed) for ~8 seconds the moment
/// biometric auth succeeded. A frozen animation is definitive proof the
/// Dart UI isolate's event loop was blocked by non-yielding synchronous
/// work: Flutter cannot render a single animation frame while the isolate
/// running it is busy. The culprit is this file's PBKDF2-HMAC-SHA512
/// (2048 rounds) seed generation — expensive pure-Dart crypto, especially
/// under Flutter's JIT/debug-mode interpreter, even called only once.
/// Moving just this step (not the cheap CKD chaining downstream of it) off
/// the UI isolate via [compute] fixes the freeze for both call sites.
///
/// **`Uint8List` migration (vault-secure-storage-redesign PR1)**: both the
/// entropy argument and the returned seed are now `Uint8List`, never a hex
/// `String`. `Uint8List` is a `TypedData` subtype, so it stays
/// `compute`/`Isolate`-sendable without any custom serialization — the
/// background-isolate offload above keeps working unchanged.
///
/// **Optional BIP-39 passphrase / "25th word" (seed-passphrase-25th-word
/// design.md D1/D2)**: both helpers below take an additive, defaulted
/// `Uint8List? passphraseUtf8` — `null`/empty means "no passphrase", the
/// exact pre-change behavior. The passphrase always travels as UTF-8 bytes,
/// never a `String` field on any long-lived object (D1); it is decoded to a
/// `String` only on the last line before handing it to
/// `Bip39SeedGenerator.generate`. [compute] accepts exactly one message, so
/// [deriveBip39SeedInBackground] packs `(entropy, passphraseUtf8)` into a
/// single isolate-sendable record (D2) rather than adding a second
/// `compute` argument.
///
/// **Required `language` (bip39-nfkd-normalization PR1/3, design.md D3)**:
/// both derivers now take a `required MnemonicLanguage language` — never
/// defaulted, so the compiler forces every call site to answer which
/// wordlist to re-encode the entropy against. This PR hardcodes
/// `MnemonicLanguage.english` at every call site (a behavioral no-op: the
/// derived seed is byte-identical to before). The isolate `compute` record
/// carries `language.wireCode` (an `int`), not the enum instance itself —
/// matching `VaultSecret`'s own isolate-sendable convention (design.md D7).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart' hide Mnemonic;
import 'package:flutter/foundation.dart' show compute;
import 'package:unorm_dart/unorm_dart.dart' show nfkd;

import '../bip39/bip39.dart';

/// `Bip39Languages` is a plain class with `static const` instances, not a
/// real Dart `enum` — so it cannot be exhaustively `switch`-matched by the
/// compiler. A `Map` literal is used instead, keyed on both sides, so a
/// missing/duplicated entry is a compile-time `const` initialization site,
/// not a silent runtime fallthrough.
const _toBip39Language = <MnemonicLanguage, Bip39Languages>{
  MnemonicLanguage.english: Bip39Languages.english,
  MnemonicLanguage.spanish: Bip39Languages.spanish,
  MnemonicLanguage.french: Bip39Languages.french,
  MnemonicLanguage.korean: Bip39Languages.korean,
  MnemonicLanguage.italian: Bip39Languages.italian,
  MnemonicLanguage.portuguese: Bip39Languages.portuguese,
  MnemonicLanguage.czech: Bip39Languages.czech,
  MnemonicLanguage.japanese: Bip39Languages.japanese,
  MnemonicLanguage.chineseSimplified: Bip39Languages.chineseSimplified,
  MnemonicLanguage.chineseTraditional: Bip39Languages.chineseTraditional,
};

final _toMnemonicLanguage = <Bip39Languages, MnemonicLanguage>{
  for (final entry in _toBip39Language.entries) entry.value: entry.key,
};

/// Maps this app's [MnemonicLanguage] to the `blockchain_utils` type the
/// BIP-39 encoder/decoder actually speaks (design.md D3). Lives here —
/// rather than a separate gateway file — because this file is already on
/// the `architecture-boundaries` R5 allowlist for `package:blockchain_utils`;
/// a second file importing that package would need a gate change, and
/// duplicating this mapping in two places is a fund-loss bug class (two
/// mappings that can diverge).
Bip39Languages bip39LanguageOf(MnemonicLanguage language) =>
    _toBip39Language[language]!;

/// The inverse of [bip39LanguageOf] (design.md D3).
MnemonicLanguage mnemonicLanguageOf(Bip39Languages language) =>
    _toMnemonicLanguage[language]!;

/// Shared function-type hook for BIP-39 seed derivation (design.md D7) —
/// used by [Bip32AccountDerivationService]'s injectable `seedFromEntropy`
/// seam so the ripple of adding [passphraseUtf8] has one canonical shape.
typedef Bip39SeedDeriver =
    Future<Uint8List> Function(
      Uint8List entropy, {
      required MnemonicLanguage language,
      Uint8List? passphraseUtf8,
    });

/// Plain top-level function (required by [compute]/`Isolate.run` — must not
/// be a closure, instance method, or capture any surrounding state, since
/// it is sent across an isolate boundary) performing the actual PBKDF2
/// derivation: entropy bytes -> BIP-39 mnemonic -> 64-byte seed.
///
/// [language] selects which wordlist the entropy is re-encoded against —
/// required, never defaulted (design.md's "Make the language a required
/// parameter, never a defaulted one, at every derivation site" decision): a
/// default here would silently re-derive a non-English vault's seed as
/// English, a fund-affecting bug.
///
/// [passphraseUtf8] is the optional BIP-39 passphrase ("25th word"),
/// UTF-8-encoded. `null` or empty means no passphrase — byte-identical to
/// this function's pre-passphrase behavior.
///
/// **The single shared passphrase-NFKD boundary (bip39-nfkd-normalization
/// PR3, design.md's "Normalize at two chokepoints" decision)**: `nfkd()`
/// runs here, on the LAST line before the passphrase becomes the PBKDF2
/// salt — never at any UI/controller call site. The passphrase is
/// re-supplied independently at generate, at commit, and at every sign
/// (`seed-passphrase`'s "Passphrase Is Re-Supplied At Every Derivation,
/// Never Cached"), so funnelling every re-entry through this one point is
/// what makes "the same typed passphrase always derives the identical
/// salt" structural, not a per-call-site discipline that one missed
/// `nfkd()` call could silently break.
Uint8List deriveBip39SeedSync(
  Uint8List entropy, {
  required MnemonicLanguage language,
  Uint8List? passphraseUtf8,
}) {
  final mnemonic = Bip39MnemonicEncoder(bip39LanguageOf(language)).encode(entropy);
  final passphrase = (passphraseUtf8 == null || passphraseUtf8.isEmpty)
      ? ''
      : nfkd(utf8.decode(passphraseUtf8));
  return Uint8List.fromList(Bip39SeedGenerator(mnemonic).generate(passphrase));
}

/// Runs [deriveBip39SeedSync] on a background isolate via [compute], so the
/// expensive PBKDF2 computation never blocks the UI isolate's event loop
/// (see this file's doc comment for the real-device evidence). [compute]
/// takes exactly one message, so [entropy], [language]'s `wireCode`, and
/// [passphraseUtf8] are packed into a single 3-field isolate-sendable
/// record — `Uint8List`/`int` are provably sendable; the enum instance
/// itself is not risked (design.md D7's convention).
Future<Uint8List> deriveBip39SeedInBackground(
  Uint8List entropy, {
  required MnemonicLanguage language,
  Uint8List? passphraseUtf8,
}) => compute(
  _deriveSeed,
  (entropy, passphraseUtf8 ?? Uint8List(0), language.wireCode),
);

/// Plain top-level function (required by [compute] — see
/// [deriveBip39SeedSync]'s doc comment) that unpacks the `(entropy,
/// passphraseUtf8, languageWireCode)` record [compute] sends across the
/// isolate boundary.
Uint8List _deriveSeed((Uint8List, Uint8List, int) request) =>
    deriveBip39SeedSync(
      request.$1,
      language: MnemonicLanguage.fromWireCode(request.$3)!,
      passphraseUtf8: request.$2,
    );
