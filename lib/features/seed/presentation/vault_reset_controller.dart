import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

/// The single, explicit, PIN-gated entry point to wiping the vault
/// (`account-deletion` spec's "PIN Re-Confirmation Required Before Wipe
/// Executes" + "Successful Wipe Removes All On-Device Account State"
/// requirements; `secure-seed-storage` spec's "Explicit User-Initiated
/// Vault Reset Only, With PIN Re-Confirmation" requirement).
///
/// **Locked decision, deliberately not implemented here or anywhere
/// else**: this controller performs no confirmation UI itself (see
/// `vault_reset_dialog.dart`/the future `/account/delete/pin` route) and
/// is NEVER wired to any app-lifecycle/background/terminate/uninstall
/// callback.
///
/// **ios-android-platform-parity-fixes PR1 (design.md D13)**: the ordered
/// wipe itself (`SealedVaultRepository.deleteBlob()`,
/// `SecureSeedRepository.deleteVault()`, `PublicAccountCache.clear()`,
/// `UnlockThrottle.clearThrottleState()`, `UnlockPreferences.
/// setBiometricEnabled(false)`) moved to `VaultWipeService` — the single
/// implementation shared with the bootstrap-time `FreshInstallGate` — and
/// this controller now reaches it only through the fakeable [vaultWiper]
/// port, calling `vaultWiper.wipe(includeIntroSeen: false)`:
/// `onboarding.intro.seen.v1` is a per-*device* fact and deliberately
/// survives account deletion (biometric-unlock-onboarding design.md
/// decision 5), unlike a fresh install's wipe. This controller keeps only
/// [sealedVaultRepository] (for the PIN-verification `readBlob()` below)
/// and [unlockThrottle] (for the charge-before-KDF rule below). The
/// structural "every secret/state-clearing method has exactly one
/// legitimate production call site" guard moved with the wipe primitives
/// to `vault_wipe_service_test.dart`'s D8 group.
///
/// **PIN verification charges the throttle** (design.md D2, mirroring
/// `EthTransactionSigner.sign`): the blob header is decoded first (pure,
/// uncharged -- a malformed/unrecognized-version blob rethrows before any
/// throttle charge), then `UnlockThrottle.recordAttemptStart()` runs
/// immediately before the KDF-costing `openVaultBlobInBackground` call, so
/// a wrong PIN is always charged. This deliberately does NOT replicate
/// `RevealSeedController.reveal`'s uncharged-PIN gap.
class VaultResetController extends ChangeNotifier {
  VaultResetController({
    required this.sealedVaultRepository,
    required this.unlockThrottle,
    required this.vaultWiper,
  });

  final SealedVaultRepository sealedVaultRepository;
  final UnlockThrottle unlockThrottle;

  /// The single, shared ordered-wipe implementation (design.md D1/D13) —
  /// called with `includeIntroSeen: false`, the ONLY difference from
  /// `FreshInstallGate`'s bootstrap-time wipe.
  final VaultWiper vaultWiper;

  AsyncState<void> _state = const AsyncIdle<void>();
  AsyncState<void> get state => _state;

  /// Whether a [confirmReset] call is currently in flight.
  bool get isResetting => _state.isLoading;

  /// Whether the most recent [confirmReset] call completed the wipe
  /// successfully.
  bool get wasReset => _state is AsyncData<void>;

  /// Verifies [pin] against the sealed vault blob and, only if it is
  /// correct, wipes all four on-device keys in D1's order. Callers MUST
  /// have already obtained explicit user confirmation before invoking this
  /// (see `showVaultResetConfirmation`).
  ///
  /// Throws [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure]
  /// (uncharged) if the stored blob does not parse -- callers should treat
  /// this like `RevealSeedController.reveal`'s same-named failures and
  /// route to the recovery flow instead of retrying the PIN. A wrong PIN
  /// becomes a retryable [AsyncError] in [state] with nothing deleted.
  Future<void> confirmReset(Uint8List pin) async {
    _state = const AsyncLoading<void>();
    notifyListeners();

    VaultSecret? secret;
    try {
      final blob = await sealedVaultRepository.readBlob();
      if (blob == null) {
        // No vault exists at all -- the router's VaultState guard should
        // already prevent reaching this screen in that state, but this
        // stays a safe no-op rather than a crash.
        _state = const AsyncError<void>('No vault is present.');
        return;
      }

      // Cheap header-only pre-check, no KDF: throws directly to the
      // caller, UNCHARGED (see this class's own doc comment).
      VaultBlob.decodeBytes(blob);

      await unlockThrottle.recordAttemptStart();

      try {
        secret = await openVaultBlobInBackground(blob: blob, pin: pin);
      } on WrongPinFailure {
        _state = const AsyncError<void>('Incorrect PIN. Please try again.');
        return;
      }

      // D8 — deliberately NO unsupported-language guard here: reset/wipe
      // is the one escape hatch that must stay reachable even for a vault
      // whose persisted language this build cannot otherwise open, or the
      // guard would permanently brick the device (design.md D8's table).
      // PIN verification alone is required to wipe -- [secret]'s language
      // is never inspected.

      // PIN verified -- delegate the ordered wipe to the shared
      // VaultWiper (design.md D13). `includeIntroSeen: false`: an account
      // deletion preserves the per-device intro-explainer flag, unlike a
      // fresh-install wipe.
      final outcome = await vaultWiper.wipe(includeIntroSeen: false);
      _state = switch (outcome) {
        VaultWipeOutcome.aborted => const AsyncError<void>(
          'Could not delete the account. Please try again.',
        ),
        VaultWipeOutcome.irreversible => const AsyncError<void>(
          'Account deleted but on-device cleanup was incomplete.',
        ),
        VaultWipeOutcome.complete => const AsyncData<void>(null),
      };
    } finally {
      secret?.zeroize();
      // Demote a still-loading state to idle without clobbering a terminal
      // AsyncData/AsyncError -- matters when an exception (e.g. a
      // malformed blob) propagates past this finally block.
      if (_state is AsyncLoading<void>) {
        _state = const AsyncIdle<void>();
      }
      notifyListeners();
    }
  }
}
