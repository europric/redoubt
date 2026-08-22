/// Shared biometric app-unlock enrollment controller — used by BOTH the
/// onboarding biometric step (`/onboarding/biometric`, this PR) and a future
/// late-enrollment settings screen (`/account/security`, PR5) per
/// biometric-unlock-onboarding design.md D6: "Late enrollment reuses
/// onboarding's controller."
///
/// **`enable()` never writes the flag on a bare capability check** — it
/// requires [AuthService.isSupported] AND a SUCCESSFUL
/// [AuthService.authenticate] call before writing
/// `vault.unlock.biometric.v1` via [UnlockPreferences]. This is deliberate:
/// never enable an unlock path the user cannot actually satisfy. `disable()`
/// needs no prompt — it only makes the app-unlock gate stricter.
library;

import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

/// The enrollment status this controller reports/drives.
enum BiometricEnrollmentStatus {
  /// The device has no biometric/passcode hardware wrap at all
  /// (`AuthService.isSupported()` is false) — the entry point offering
  /// enrollment should not be shown.
  unsupported,

  /// The device supports biometrics, but they are not currently enrolled
  /// for app-unlock (never enabled, explicitly [disable]d, or a prior
  /// [enable] attempt failed/was cancelled).
  declined,

  /// Biometric app-unlock is currently enrolled (`vault.unlock.biometric.v1`
  /// is `true`).
  enabled,
}

class BiometricEnrollmentController extends ChangeNotifier {
  BiometricEnrollmentController({
    required this.authService,
    required this.unlockPreferences,
  });

  final AuthService authService;
  final UnlockPreferences unlockPreferences;

  AsyncState<BiometricEnrollmentStatus> _state =
      const AsyncIdle<BiometricEnrollmentStatus>();
  AsyncState<BiometricEnrollmentStatus> get state => _state;

  /// Computes the current [BiometricEnrollmentStatus] from
  /// [AuthService.isSupported] and the persisted flag, without prompting.
  Future<void> load() async {
    _state = const AsyncLoading<BiometricEnrollmentStatus>();
    notifyListeners();

    if (!await authService.isSupported()) {
      _state = const AsyncData(BiometricEnrollmentStatus.unsupported);
      notifyListeners();
      return;
    }

    final enabled = await unlockPreferences.getBiometricEnabled();
    _state = AsyncData(
      enabled
          ? BiometricEnrollmentStatus.enabled
          : BiometricEnrollmentStatus.declined,
    );
    notifyListeners();
  }

  /// Prompts the user via [AuthService.authenticate]. The flag is written
  /// (and [state] lands on [BiometricEnrollmentStatus.enabled]) ONLY on a
  /// successful prompt. Returns `false` — writing nothing — when the device
  /// is unsupported, or the prompt is denied, cancelled, or fails; [state]
  /// in that case lands on [BiometricEnrollmentStatus.declined].
  Future<bool> enable() async {
    if (!await authService.isSupported()) {
      _state = const AsyncData(BiometricEnrollmentStatus.unsupported);
      notifyListeners();
      return false;
    }

    final authenticated = await authService.authenticate();
    if (!authenticated) {
      _state = const AsyncData(BiometricEnrollmentStatus.declined);
      notifyListeners();
      return false;
    }

    await unlockPreferences.setBiometricEnabled(true);
    _state = const AsyncData(BiometricEnrollmentStatus.enabled);
    notifyListeners();
    return true;
  }

  /// Turns biometric app-unlock off. No prompt — disabling only makes the
  /// gate stricter, so it needs no proof of possession.
  Future<void> disable() async {
    await unlockPreferences.setBiometricEnabled(false);
    _state = const AsyncData(BiometricEnrollmentStatus.declined);
    notifyListeners();
  }
}
