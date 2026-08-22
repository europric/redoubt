/// The single, ordered on-device wipe implementation (`ios-android-
/// platform-parity-fixes` design.md D1/D2) — the sole [VaultWiper]
/// implementation in the codebase.
///
/// **`lib/config/` location, not `lib/core/security/` (design.md D1)**:
/// this class must reach FIVE collaborators, one of which —
/// [PublicAccountCache] — lives in `lib/features/account/`. R2's
/// `case _Layer.coreOther` allows `core/**` to import ONLY `core/**`, so a
/// wipe implementation inside `lib/core/security/` cannot compile. R2's
/// `case _Layer.config` returns `true` unconditionally (composition root),
/// matching `lib/config/vault_commit_service.dart`'s exact same shape.
/// `VaultResetController`/`FreshInstallGate` receive this only through the
/// [VaultWiper] port, by injection — the correct dependency-inversion
/// direction, mirroring `lib/config/adapters/cached_account_address_source.dart`.
///
/// **Step order is D2's fixed, gate-then-best-effort order**: step 1
/// (`deleteBlob`) gates the rest — if it throws, [wipe] aborts immediately
/// with nothing else touched. Once step 1 commits, the account is already
/// unrecoverable, so steps 2-6 all run unconditionally (collecting
/// failures) to minimise residue, even if an earlier one already failed.
/// [includeIntroSeen] controls ONLY step 6 — see [VaultWiper.wipe]'s own
/// doc comment for why that single flag is the entire difference between
/// this class's two production callers.
library;

import '../core/security/security.dart';
import '../features/account/account.dart';

class VaultWipeService implements VaultWiper {
  const VaultWipeService({
    required this.sealedVaultRepository,
    required this.seedRepository,
    required this.accountCache,
    required this.unlockThrottle,
    required this.unlockPreferences,
  });

  /// Builds the production instance, reusing [seedRepository] (the RAW,
  /// non-biometric-gated repository — legacy-key cleanup must always
  /// succeed regardless of biometric hardware availability, matching
  /// `VaultCommitService`'s own established convention) and
  /// [unlockPreferences], both of which `main.dart` already constructs once
  /// and reuses elsewhere. Every other collaborator is constructed fresh
  /// here, matching `VaultScope.production`'s own instance-per-key
  /// convention.
  factory VaultWipeService.production({
    required SecureSeedRepository seedRepository,
    required UnlockPreferences unlockPreferences,
  }) => VaultWipeService(
    sealedVaultRepository: const FlutterSealedVaultRepository(),
    seedRepository: seedRepository,
    accountCache: const FlutterPublicAccountCache(),
    unlockThrottle: const FlutterUnlockThrottle(),
    unlockPreferences: unlockPreferences,
  );

  final SealedVaultRepository sealedVaultRepository;
  final SecureSeedRepository seedRepository;
  final PublicAccountCache accountCache;
  final UnlockThrottle unlockThrottle;
  final UnlockPreferences unlockPreferences;

  @override
  Future<VaultWipeOutcome> wipe({required bool includeIntroSeen}) async {
    // Step 1 -- the gate. Nothing else runs if this throws.
    try {
      await sealedVaultRepository.deleteBlob();
    } catch (_) {
      return VaultWipeOutcome.aborted;
    }

    // Steps 2-6 -- best-effort, unconditional. Every step is attempted
    // regardless of earlier failures, to minimise residue.
    var cleanupFailed = false;

    try {
      await seedRepository.deleteVault();
    } catch (_) {
      cleanupFailed = true;
    }
    try {
      await accountCache.clear();
    } catch (_) {
      cleanupFailed = true;
    }
    try {
      await unlockThrottle.clearThrottleState();
    } catch (_) {
      cleanupFailed = true;
    }
    try {
      await unlockPreferences.setBiometricEnabled(false);
    } catch (_) {
      cleanupFailed = true;
    }
    if (includeIntroSeen) {
      try {
        await unlockPreferences.setIntroSeen(false);
      } catch (_) {
        cleanupFailed = true;
      }
    }

    return cleanupFailed
        ? VaultWipeOutcome.irreversible
        : VaultWipeOutcome.complete;
  }
}
