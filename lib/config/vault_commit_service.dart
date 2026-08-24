/// Orchestrates a seed-commit: seals [entropy] under a PIN-derived Argon2id
/// KEK, persists it as the vault's v1 sealed blob, and caches the resulting
/// public account data — all in one call.
///
/// **`lib/config/` location (hexagonal-architecture-refactor design.md
/// D6)**: moved from `lib/core/security/`. This is composition-root
/// orchestration, not a feature service — it depends on both the `account`
/// feature's [AccountDerivationService]/[PublicAccountCache] domain ports
/// and the `vault` (seed) feature's [SeedCommitter] port in the same file,
/// and cross-feature `domain/`-to-`domain/` dependencies are otherwise
/// disallowed by the architecture-boundaries rules; only `lib/config/**`
/// may orchestrate across two features' domains in one file.
///
/// **`VaultSealer` injection (design.md D10, `VaultCipher.seal Is
/// Injected` requirement)**: [seal] is a constructor-injected function,
/// defaulted to the [VaultCipher.seal] static tear-off. `commit()` calls
/// the injected `seal` field, never `VaultCipher.seal` as a direct static
/// call — a fake `VaultSealer`
/// can therefore be substituted in tests. The tear-off default is a
/// compile-time constant (extra optional named params on `VaultCipher.seal`
/// make it a valid subtype of [VaultSealer]), so this class's `const`
/// constructor and existing production call sites are unaffected.
///
/// **v1 cutover (vault-secure-storage-redesign PR7, task 8.5)**: supersedes
/// PR2's v0, which wrote the LEGACY plaintext-hex entropy format. This is
/// now the sole production seed-commit path (wired into `SeedVerifyController`/
/// `SeedImportController`'s PIN-setup step, both via the [SeedCommitter]
/// port) — a real seed commit produces a real `vault.seed.v1` blob, so
/// `VaultStateProbe` correctly reports [VaultState.current] afterward.
///
/// **Ordering is load-bearing** (design.md's Data Flow section): `derive()`
/// -> `seal(entropy, pin)` -> write `vault.seed.v1` (MUST complete before
/// the cache write) -> write `vault.account.public.v1` -> delete
/// `vault.seed.entropy` (legacy cleanup, best-effort last step) -> `finally`
/// zeroize [entropy] and [pin]. A failed blob write must never leave a
/// cache entry advertising an address for a vault that doesn't actually
/// exist — reversing this order could do exactly that.
///
/// [seedRepository] is used ONLY for its `deleteVault()` legacy-cleanup
/// call now — it is deliberately the RAW (non-biometric-gated) repository
/// in production wiring (`VaultScope.production`), not the
/// `AuthenticatedSeedRepository` decorator: legacy-key cleanup must always
/// succeed regardless of whether biometric hardware is available, matching
/// this codebase's existing convention of never gating non-secret-revealing
/// housekeeping operations behind biometrics (see `hasSeed()`'s own
/// deliberately-ungated precedent).
library;

import 'dart:typed_data';

import '../core/bip39/bip39.dart';
import '../core/security/sealed_vault_repository.dart';
import '../core/security/secure_seed_repository.dart';
import '../core/security/vault_cipher.dart';
import '../core/security/vault_plaintext.dart';
import '../features/account/domain/account_derivation_service.dart';
import '../features/account/domain/public_account_cache.dart';
import '../features/seed/domain/seed_committer.dart';

/// Function shape of [VaultCipher.seal] — injected so [VaultCommitService]
/// never invokes it as a static call inside its own method body (design.md
/// D10). [VaultCipher.seal]'s extra optional named parameters
/// (`costParams`, `aeadId`) make the static tear-off a valid subtype of
/// this narrower signature.
typedef VaultSealer =
    Future<Uint8List> Function({
      required Uint8List plaintext,
      required Uint8List pin,
    });

class VaultCommitService implements SeedCommitter {
  const VaultCommitService({
    required this.seedRepository,
    required this.sealedVaultRepository,
    required this.derivationService,
    required this.accountCache,
    this.seal = VaultCipher.seal,
  });

  /// Legacy-cleanup only now — see this file's own doc comment.
  final SecureSeedRepository seedRepository;
  final SealedVaultRepository sealedVaultRepository;
  final AccountDerivationService derivationService;
  final PublicAccountCache accountCache;

  /// Injected seal operation (design.md D10) — defaults to
  /// [VaultCipher.seal].
  final VaultSealer seal;

  /// Persists [entropy] sealed under [pin], then derives and caches the
  /// public account data it yields. Returns the [DerivedAccount] bundle so
  /// callers (e.g. a controller wanting to populate its own state) don't
  /// need a second derivation. [entropy], [pin], and [passphraseUtf8] (when
  /// provided) are zeroized in a `finally` block regardless of success or
  /// failure — callers MUST treat all three as consumed after this call
  /// returns or throws.
  ///
  /// [passphraseUtf8] is the optional BIP-39 passphrase ("25th word",
  /// seed-passphrase-25th-word design.md D1), UTF-8-encoded. `null` or
  /// empty means no passphrase — forwarded unchanged to
  /// [AccountDerivationService.derive]; this method never inspects or
  /// transforms it itself.
  ///
  /// Returns `Future<DerivedAccount>` — a valid override of [SeedCommitter]
  /// interface's `Future<void> commit(...)` (design.md D6): both
  /// `SeedVerifyController.commitWithPin` and
  /// `SeedImportController.commitWithPin` already discard this return
  /// value, so implementing [SeedCommitter] required no signature change
  /// here.
  @override
  Future<DerivedAccount> commit(
    Uint8List entropy,
    Uint8List pin, {
    required MnemonicLanguage language,
    Uint8List? passphraseUtf8,
  }) async {
    // Phase 2 (design.md D6): the sealed plaintext now carries the
    // committed [language] framed alongside entropy, encrypted under the
    // same PIN-derived AEAD as the entropy itself — never in cleartext or
    // as AAD. Built BEFORE the try block so the `finally` below can zeroize
    // it unconditionally, mirroring [entropy]/[pin]'s own convention.
    final plaintext = VaultPlaintext.encode(entropy: entropy, language: language);
    try {
      final derived = await derivationService.derive(
        entropy,
        language: language,
        passphraseUtf8: passphraseUtf8,
      );

      final blob = await seal(plaintext: plaintext, pin: pin);
      // MUST come first — see this file's own doc comment on why the
      // ordering is load-bearing.
      await sealedVaultRepository.writeBlob(blob);

      try {
        await accountCache.write(
          account: derived.account,
          derivationPath: kAccountDerivationPath,
          pairing: derived.pairingKey,
        );
      } catch (e) {
        // Rollback: blob was durably written but the cache write failed —
        // delete the blob to prevent an orphan vault that the D5 guard
        // can't verify.
        try {
          await sealedVaultRepository.deleteBlob();
        } catch (_) {
          // Double fault: the rollback itself also failed. Swallow this
          // failure and rethrow the original cache-write exception — the
          // caller needs to know why commit() failed, not that cleanup
          // stumbled afterward.
        }
        rethrow;
      }

      // Legacy cleanup: only reached once the new blob + cache are both
      // durably written. Harmless no-op if no legacy key ever existed.
      await seedRepository.deleteVault();

      return derived;
    } finally {
      entropy.fillRange(0, entropy.length, 0);
      pin.fillRange(0, pin.length, 0);
      passphraseUtf8?.fillRange(0, passphraseUtf8.length, 0);
      // [plaintext] is a DISTINCT buffer from [entropy] (it copies the
      // entropy bytes into a new, 2-byte-longer array) — zeroize it too,
      // or a decrypted-shaped copy of the language-framed entropy would
      // survive in memory after this method returns/throws.
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }
}
