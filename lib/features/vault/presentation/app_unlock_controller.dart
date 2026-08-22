/// Owns the `app-unlock-gate` capability's biometric-first / PIN-fallback
/// logic (route `/unlock`, biometric-unlock-onboarding design.md D1/D2).
/// Composed by `AppUnlockPage`.
///
/// **Visibility gate only, never exposes seed material**: [submitPin]
/// discards the decrypted entropy it opens the vault with — it is never
/// returned, never stored on `this`, and is zero-filled in a `finally`
/// block before the method returns (success OR failure), mirroring
/// `VaultResetController.confirmReset`'s own zeroization discipline. Passing
/// this gate never derives an exposable KEK/mnemonic and never substitutes
/// for the separate PIN + device-auth required by sign/reveal-seed/delete
/// (`app-unlock-gate` spec's "PIN Fallback Reuses The Existing Vault-Unseal
/// Path And Never Bypasses Seed-Material Auth" requirement).
///
/// **D1 — the real Argon2id vault open runs on the PIN path only**:
/// [submitPin] replays `VaultResetController.confirmReset`'s exact prelude
/// -- `readBlob()` -> uncharged [VaultBlob.decodeBytes] header pre-check ->
/// `unlockThrottle.recordAttemptStart()` -> `openVaultBlobInBackground()`.
/// [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure] propagate
/// UNCHARGED to the caller (same as `EthTransactionSigner.sign`/
/// `VaultResetController.confirmReset`) -- the caller (`AppUnlockPage`)
/// should route to vault recovery instead of offering a PIN retry.
/// [WrongPinFailure] is caught here and turned into a retryable
/// [AsyncError]. A successful biometric unlock ([attemptBiometric]) never
/// touches [sealedVaultRepository]/the KDF at all -- zero Argon2id cost.
///
/// **D2 — one shared [UnlockThrottle], biometric failure charges nothing**:
/// unlike `EthTransactionSigner.sign`, [attemptBiometric] NEVER calls
/// [UnlockThrottle.recordAttemptStart] -- a denied/failed/cancelled
/// biometric prompt is free, and [showPinFallback] flips to `true`
/// immediately so PIN entry is reachable with no backoff/lockout blocking
/// the PIN entry UI itself. Only a submitted PIN (via [submitPin]) ever
/// charges the throttle, exactly like `VaultResetController.confirmReset`'s
/// existing invariant.
library;

import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

class AppUnlockController extends ChangeNotifier {
  AppUnlockController({
    required this.authService,
    required this.unlockPreferences,
    required this.sealedVaultRepository,
    required this.unlockThrottle,
  });

  final AuthService authService;
  final UnlockPreferences unlockPreferences;
  final SealedVaultRepository sealedVaultRepository;
  final UnlockThrottle unlockThrottle;

  /// `true` once either [attemptBiometric] or [submitPin] succeeds. The
  /// caller (`AppUnlockPage`) reacts to this transition by invoking its own
  /// `onUnlocked` callback -- this controller never navigates itself.
  AsyncState<bool> _state = const AsyncIdle<bool>();
  AsyncState<bool> get state => _state;

  /// Whether the PIN-fallback UI should be shown. Starts `false` (the
  /// automatic biometric attempt is still pending/in flight); flips to
  /// `true` the moment biometrics are unenrolled, or a biometric attempt is
  /// denied/fails/is cancelled -- reachable immediately, per D2.
  bool _showPinFallback = false;
  bool get showPinFallback => _showPinFallback;

  /// Whether biometric app-unlock is currently enrolled -- drives whether
  /// `AppUnlockPage` offers the retry-biometric key at all (`app-unlock-gate`
  /// spec's "Retry key appears ... with biometrics enrolled" scenario: the
  /// key is never shown when there is nothing to retry).
  bool _biometricEnabled = false;
  bool get biometricEnabled => _biometricEnabled;

  /// The modality to represent for the retry key's icon (design.md D4/D7),
  /// refreshed alongside every [attemptBiometric] call.
  BiometricKind _biometricKind = BiometricKind.none;
  BiometricKind get biometricKind => _biometricKind;

  /// Attempts biometric-or-passcode auth automatically when biometrics were
  /// enrolled for app-unlock (`app-unlock-gate` spec's "Biometric First When
  /// Enrolled, Immediate PIN Fallback Otherwise" requirement). When
  /// biometrics are unenrolled, this never calls [AuthService.authenticate]
  /// at all and flips [showPinFallback] straight to `true`
  /// (`no biometric prompt attempted` scenario).
  Future<void> attemptBiometric() async {
    _biometricEnabled = await unlockPreferences.getBiometricEnabled();
    if (!_biometricEnabled) {
      _showPinFallback = true;
      notifyListeners();
      return;
    }

    _biometricKind = await authService.availableBiometric();
    _state = const AsyncLoading<bool>();
    notifyListeners();

    final ok = await authService.authenticate();
    if (ok) {
      _state = const AsyncData<bool>(true);
      notifyListeners();
      return;
    }

    // Denied, cancelled, or failed -- D2: never charges the throttle, and
    // PIN entry becomes immediately reachable, no delay/lockout.
    _state = const AsyncIdle<bool>();
    _showPinFallback = true;
    notifyListeners();
  }

  /// PIN fallback -- see this class's own doc comment for D1's exact
  /// prelude. [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure]
  /// propagate uncaught; [WrongPinFailure] becomes a retryable [AsyncError].
  Future<void> submitPin(Uint8List pin) async {
    _state = const AsyncLoading<bool>();
    notifyListeners();

    VaultSecret? secret;
    try {
      final blob = await sealedVaultRepository.readBlob();
      if (blob == null) {
        // No vault exists at all -- the router's VaultState guard should
        // already prevent reaching this screen in that state, but this
        // stays a safe no-op rather than a crash.
        _state = const AsyncError<bool>('No vault is present.');
        return;
      }

      // Cheap header-only pre-check, no KDF: throws directly to the
      // caller, UNCHARGED (see this class's own doc comment).
      VaultBlob.decodeBytes(blob);

      await unlockThrottle.recordAttemptStart();

      try {
        secret = await openVaultBlobInBackground(blob: blob, pin: pin);
      } on WrongPinFailure {
        _state = const AsyncError<bool>('Incorrect PIN. Please try again.');
        return;
      }

      await unlockThrottle.recordSuccess();

      // D8 guard — placed AFTER recordSuccess(): the PIN was genuinely
      // correct, so the throttle must clear even for a vault whose
      // persisted language this build cannot honor. Terminal and
      // non-retryable -- never falls back to unlocking against a
      // substituted default language.
      try {
        secret.requireLanguage();
      } on UnsupportedMnemonicLanguageFailure {
        _state = const AsyncError<bool>(
          'This vault was created with a recovery phrase language this '
          'app version cannot open. Update the app.',
        );
        return;
      }

      // Visibility gate only -- entropy is discarded (zeroized below),
      // NEVER exposed to the caller or stored on this controller (see this
      // class's own doc comment).
      _state = const AsyncData<bool>(true);
    } finally {
      secret?.zeroize();
      // Demote a still-loading state to idle without clobbering a terminal
      // AsyncData/AsyncError -- matters when an exception (e.g. a malformed
      // blob) propagates past this finally block.
      if (_state is AsyncLoading<bool>) {
        _state = const AsyncIdle<bool>();
      }
      notifyListeners();
    }
  }
}
