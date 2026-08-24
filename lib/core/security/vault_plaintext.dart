/// Framed sealed-plaintext codec (design.md D6) — what actually lives
/// inside the AEAD ciphertext that `VaultCipher.seal`/`open` produce and
/// consume. `VaultBlob`'s header layout and version byte are **unchanged**
/// (no `v2` bump); the source-language marker travels encrypted alongside
/// the entropy instead, so it is covered by the same PIN-derived AEAD as
/// the entropy itself and never appears in cleartext or as AAD (confirmed
/// Question Round A).
///
/// **Layout**:
/// ```
/// framed plaintext = [0x01 version][wireCode uint8][entropy …]   // 2 + n
/// legacy plaintext = [entropy …]                                 // n
/// ```
///
/// **Deserialization rule (absent ⇒ English), provably unambiguous**:
///
/// | `plaintext.length`        | Interpretation                              |
/// |----------------------------|---------------------------------------------|
/// | ∈ {16, 20, 24, 28, 32}     | Legacy (pre-change) — entropy as-is, English |
/// | ∈ {18, 22, 26, 30, 34} **and** `[0] == 0x01` | Framed — `wireCode = [1]`, entropy = `sublist(2)` |
/// | anything else              | [MalformedVaultPlaintextFailure]             |
///
/// The two length sets are disjoint (today's 5 valid BIP-39 entropy sizes,
/// vs. those same 5 sizes plus the 2 framing bytes), so "field absent"
/// never needs a magic-number heuristic or probabilistic detection — every
/// vault committed before this capability existed only ever wrote a bare
/// legacy-length plaintext, because import only ever accepted English
/// before this change (proposal's rollout argument).
///
/// **All new writes are framed, including English** — `VaultCommitService`
/// always calls [VaultPlaintext.encode], never writes a bare legacy
/// plaintext itself. Only a genuinely pre-change blob is ever legacy-shaped
/// on read.
library;

import 'dart:typed_data';

import '../bip39/bip39.dart';

/// v1 sealed-plaintext frame version byte.
const int _kFrameVersion = 0x01;

/// Today's valid BIP-39 entropy byte lengths (12/15/18/21/24-word
/// mnemonics) — a bare plaintext at one of these lengths is a pre-change
/// (legacy) vault, provably English (see this file's doc comment).
const Set<int> _kLegacyEntropyLengths = {16, 20, 24, 28, 32};

/// [_kLegacyEntropyLengths] plus the 2-byte frame prefix — proven disjoint
/// from [_kLegacyEntropyLengths] by `vault_plaintext_test.dart`'s dedicated
/// assertion, which is the entire correctness argument for "absent field
/// means English" requiring no heuristic.
const Set<int> _kFramedTotalLengths = {18, 22, 26, 30, 34};

/// Thrown when a plaintext's byte length matches neither a legacy nor a
/// framed shape, or matches a framed length but its first byte is not
/// [_kFrameVersion]. A format issue, distinct from
/// [UnsupportedMnemonicLanguageFailure] (well-formed frame, unrecognized
/// language) — mirrors `vault_blob.dart`'s
/// [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure] split.
class MalformedVaultPlaintextFailure implements Exception {
  const MalformedVaultPlaintextFailure(this.message);

  final String message;

  @override
  String toString() => 'MalformedVaultPlaintextFailure: $message';
}

/// Thrown by [VaultSecret.requireLanguage] when the persisted language wire
/// code does not match any [MnemonicLanguage] this build recognizes
/// (design.md D8's loud guard — confirmed Question Round C: "refuse to
/// open with an explicit error rather than silently deriving a different,
/// valid-looking, empty wallet"). Because [MnemonicLanguage] (D2) is total
/// over today's `Bip39Languages`, the realistic trigger is a downgrade: a
/// build older than the one that wrote this vault.
class UnsupportedMnemonicLanguageFailure implements Exception {
  const UnsupportedMnemonicLanguageFailure(this.wireCode);

  final int wireCode;

  @override
  String toString() =>
      'UnsupportedMnemonicLanguageFailure: unrecognized language wire code '
      '$wireCode';
}

/// The decoded result of opening a vault's sealed plaintext: the raw
/// entropy bytes plus the persisted language, still as a raw wire code
/// (not yet resolved to a [MnemonicLanguage] — resolution is deferred to
/// [requireLanguage] so callers that must never silently substitute a
/// default, per design.md D8, are forced to handle the unsupported case
/// explicitly).
///
/// **Isolate-sendable convention (design.md D7)**: [VaultCipher]'s
/// `openVaultBlobInBackground` decodes the framing INSIDE the background
/// isolate and sends back a `(Uint8List, int)` record, wrapping it into a
/// [VaultSecret] only on the caller's isolate — `Uint8List`/`int` are
/// provably sendable; this class instance itself is never risked crossing
/// the isolate boundary.
class VaultSecret {
  VaultSecret({
    required this.entropy,
    required this.languageWireCode,
    required this.isFramed,
  });

  final Uint8List entropy;
  final int languageWireCode;

  /// Whether this secret came from a framed plaintext (v1+ format written by
  /// [VaultPlaintext.encode]) or a bare legacy plaintext (pre-change format).
  ///
  /// The D5 address-match guard in [EthTransactionSigner] uses this to
  /// distinguish a post-cache vault whose cache write may have failed (framed,
  /// block on null committed address) from a pre-cache vault that never had a
  /// committed address at all (legacy, proceed on null for backward compat).
  final bool isFramed;

  /// Resolves [languageWireCode] to a [MnemonicLanguage], or throws
  /// [UnsupportedMnemonicLanguageFailure] when this build does not
  /// recognize it — design.md D8's loud guard. Callers that must never
  /// substitute a default (unlock, sign, reveal) call this explicitly;
  /// `VaultResetController.confirmReset` deliberately does NOT, so the
  /// wipe escape hatch stays reachable even for an unsupported-language
  /// vault.
  MnemonicLanguage requireLanguage() {
    final language = MnemonicLanguage.fromWireCode(languageWireCode);
    if (language == null) {
      throw UnsupportedMnemonicLanguageFailure(languageWireCode);
    }
    return language;
  }

  /// Zero-fills [entropy] in place. Callers own calling this exactly once,
  /// in a `finally` block, once they are done with the decrypted entropy —
  /// same convention as every other raw-secret buffer in this codebase
  /// (`VaultCipher.open`'s doc comment, `EthTransactionSigner.sign`'s
  /// `finally` block).
  void zeroize() {
    entropy.fillRange(0, entropy.length, 0);
  }
}

/// Pure functions only — no I/O, no crypto. Operates on the plaintext
/// bytes AFTER `VaultCipher.open` has already decrypted them (or BEFORE
/// `VaultCipher.seal` encrypts them) — this file never touches the AEAD
/// ciphertext or the `VaultBlob` header.
abstract final class VaultPlaintext {
  /// Builds the framed plaintext `VaultCommitService` seals: always framed,
  /// even for English (design.md D6 — "all new writes are framed").
  static Uint8List encode({
    required Uint8List entropy,
    required MnemonicLanguage language,
  }) {
    final out = Uint8List(entropy.length + 2);
    out[0] = _kFrameVersion;
    out[1] = language.wireCode;
    out.setRange(2, out.length, entropy);
    return out;
  }

  /// Decodes [plaintext] per this file's doc-comment table. Throws
  /// [MalformedVaultPlaintextFailure] for a length matching neither shape,
  /// or a framed-length plaintext whose first byte isn't [_kFrameVersion].
  /// Never throws for an unrecognized (but well-formed) language wire code
  /// — that is [VaultSecret.requireLanguage]'s job (D8), so a caller like
  /// `VaultResetController.confirmReset` can decode without being forced
  /// to handle the guard.
  static VaultSecret decode(Uint8List plaintext) {
    final length = plaintext.length;

    if (_kLegacyEntropyLengths.contains(length)) {
      return VaultSecret(
        entropy: Uint8List.fromList(plaintext),
        languageWireCode: MnemonicLanguage.english.wireCode,
        isFramed: false,
      );
    }

    if (_kFramedTotalLengths.contains(length) &&
        plaintext[0] == _kFrameVersion) {
      return VaultSecret(
        entropy: Uint8List.fromList(plaintext.sublist(2)),
        languageWireCode: plaintext[1],
        isFramed: true,
      );
    }

    throw MalformedVaultPlaintextFailure(
      'plaintext is $length bytes, matching neither a legacy entropy '
      'length ($_kLegacyEntropyLengths) nor a framed length '
      '($_kFramedTotalLengths) with a recognized frame version byte',
    );
  }
}
