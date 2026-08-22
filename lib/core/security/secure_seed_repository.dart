/// The fakeable domain boundary over encrypted seed storage.
///
/// **Deviation from `tasks.md`'s originally suggested file path**
/// (`lib/features/seed/data/secure_seed_repository.dart`): this PR (PR3,
/// Phase 3) is explicitly scoped to `lib/core/security/` only — `lib/features/`
/// is out of scope until Phase 4. Placing the interface and its
/// implementations here keeps them usable by both the (not-yet-built) seed
/// feature and the signing feature without a premature `lib/features/seed/`
/// skeleton. Phase 4 will decide whether `lib/features/seed/domain/` simply
/// re-exports this interface or defines its own that delegates to it.
///
/// Only the BIP-39 **entropy** is ever persisted, under one key
/// (`vault.seed.entropy`, see [FlutterSecureSeedRepository]). A mnemonic
/// string and any derived private key are NEVER written to storage —
/// per `secure-seed-storage` spec's "Signing Keys Are Derived Transiently,
/// Never Persisted" requirement.
///
/// **`Uint8List` migration (vault-secure-storage-redesign PR1)**: entropy is
/// now `Uint8List` end-to-end on this interface, never a hex `String` —
/// `secure-seed-storage`'s "Entropy held as Uint8List end-to-end" scenario.
/// Hex encoding/decoding exists ONLY at the storage boundary inside
/// [FlutterSecureSeedRepository] (`flutter_secure_storage` only accepts
/// `String` values); the bytes actually persisted are unchanged by this
/// migration. Callers MUST zeroize the returned buffer (via `fillRange`)
/// once they are done with it.
library;

import 'dart:typed_data';

abstract interface class SecureSeedRepository {
  /// Persists [entropy] as the vault's seed material. Overwrites any
  /// previously stored entropy.
  Future<void> writeEntropy(Uint8List entropy);

  /// Reads the stored entropy bytes, or `null` if no seed has been
  /// persisted. Callers MUST zeroize the returned buffer once done.
  Future<Uint8List?> readEntropy();

  /// Whether a seed currently exists in storage. This is a key-presence
  /// check only — it does not decrypt or read the value, so callers MUST
  /// NOT treat it as an auth-gated operation (see `main.dart`'s bootstrap
  /// use in design.md's Route Map section).
  Future<bool> hasSeed();

  /// Explicit, user-initiated wipe of the stored seed (locked decision:
  /// `secure-seed-storage` spec's "Explicit User-Initiated Vault Reset
  /// Only" requirement — NEVER call this from an app-lifecycle callback).
  Future<void> deleteVault();
}
