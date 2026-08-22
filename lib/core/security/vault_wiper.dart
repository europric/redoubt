/// The fakeable port over the app's single, ordered on-device wipe
/// (`ios-android-platform-parity-fixes` design.md D1/D2/D3).
///
/// **One implementation, two callers, one boolean difference.** The only
/// production implementation is `lib/config/vault_wipe_service.dart`'s
/// `VaultWipeService` (it must live in `lib/config`, not here — see that
/// file's own doc comment for the architecture-boundaries reason, D1). Its
/// two callers are `VaultResetController.confirmReset` (explicit,
/// PIN-gated account deletion — `includeIntroSeen: false`) and
/// `FreshInstallGate` (bootstrap, pre-`runApp` — `includeIntroSeen: true`).
///
/// Zero imports outside `dart:*` — this file must stay importable from both
/// `core/security` (this port lives here) and reachable, by injection only,
/// from `lib/features/**` presentation code, without ever pulling
/// `lib/config` or `lib/features/account` into `core/security`'s own
/// dependency graph (R2's `coreOther -> coreOther` rule).
library;

/// The three possible results of a [VaultWiper.wipe] call — deliberately
/// three-valued, not a `bool`, because the difference between "nothing was
/// deleted" ([aborted]) and "the vault is gone but cleanup was incomplete"
/// ([irreversible]) is the single fact [FreshInstallGate]'s anti-wipe-loop
/// safety rule depends on (design.md D3/D5).
enum VaultWipeOutcome {
  /// The first (gating) step threw. Nothing was deleted. The vault is
  /// STILL RECOVERABLE — the caller may safely retry.
  aborted,

  /// The gating step committed, but at least one later best-effort step
  /// failed. The vault is gone; some non-secret residue may remain.
  irreversible,

  /// Every requested step succeeded.
  complete,
}

/// The fakeable boundary over the app's single, ordered wipe.
abstract interface class VaultWiper {
  /// Wipes on-device account state in a fixed, gate-then-best-effort order
  /// (design.md D2): once the first (gating) step commits, every remaining
  /// step is attempted unconditionally, even if an earlier one already
  /// failed, to minimise residue.
  ///
  /// [includeIntroSeen] is the ONLY difference between the two production
  /// callers:
  ///   - `false` -> account deletion; `onboarding.intro.seen.v1` is
  ///     PRESERVED (it is a per-device fact, not a per-account one).
  ///   - `true`  -> fresh install; `onboarding.intro.seen.v1` is CLEARED,
  ///     so a reinstall walks the intro explainer again.
  ///
  /// Never throws: every failure is reported through the returned
  /// [VaultWipeOutcome], never via an exception escaping this call.
  Future<VaultWipeOutcome> wipe({required bool includeIntroSeen});
}
