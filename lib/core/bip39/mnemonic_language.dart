/// App-owned mirror of `blockchain_utils`'s `Bip39Languages` (design.md D1).
///
/// **Why this exists instead of using `Bip39Languages` directly**: the
/// `architecture-boundaries` CI gate's R5 allowlists `package:blockchain_utils`
/// to exactly 5 files, none under `features/seed/domain/**` — and R2 forbids
/// `core/**` from importing `features/**`. The mnemonic-decode boundary
/// (`bip39_mnemonic_service.dart`) and the vault-plaintext codec
/// (`core/security/vault_plaintext.dart`, Phase 2) both need this type, and
/// the latter can *only* live under `core/`. A `features/`-owned enum is
/// therefore not merely inelegant here — it is structurally impossible.
/// `lib/core/eth/bip39_seed.dart` maps to/from `Bip39Languages` at the data
/// boundary (design.md D3) so this file itself stays dependency-free.
///
/// **Total over today's `Bip39Languages`, not just the 4 claimed languages**
/// (design.md D2): `Bip39MnemonicDecoder`'s language detection
/// (`Bip39WordsListFinder.findLanguage`) iterates every `Bip39Languages`
/// value. A narrower enum would force a *rejection* of a valid phrase (e.g.
/// Italian) that NFKD normalization already makes decodable — a regression
/// against the confirmed "normalize universally, claim only 3" decision.
/// "Claim only 3" is a testing/release-notes boundary, not a code boundary.
///
/// **Explicit `wireCode`, never `Index`**: the value persisted (encrypted)
/// with the vault in Phase 2. A future reordering of this enum's declaration
/// must never silently repoint an already-committed vault to a different
/// language — `Index` is order-dependent, `wireCode` is not.
enum MnemonicLanguage {
  english(0),
  spanish(1),
  french(2),
  korean(3),
  italian(4),
  portuguese(5),
  czech(6),
  japanese(7),
  chineseSimplified(8),
  chineseTraditional(9);

  const MnemonicLanguage(this.wireCode);

  /// The stable, explicit wire representation of this language — what gets
  /// persisted (Phase 2's framed sealed plaintext), never this enum's
  /// declaration-order `index`.
  final int wireCode;

  /// Reverses [wireCode] back to its [MnemonicLanguage], or `null` when
  /// [code] does not match any known member — the trigger for design.md
  /// D8's loud "unsupported mnemonic language" guard (e.g. a vault written
  /// by a newer build that added an 11th language, opened by an older one).
  static MnemonicLanguage? fromWireCode(int code) {
    for (final language in values) {
      if (language.wireCode == code) return language;
    }
    return null;
  }
}
