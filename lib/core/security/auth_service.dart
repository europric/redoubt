/// The fakeable boundary for biometric-or-passcode authentication gating
/// access to the vault's seed.
///
/// Per `secure-seed-storage` spec's "Biometric-Gated Access With Passcode
/// Fallback" requirement: successful biometric auth grants access; when no
/// biometric is enrolled the OS-native passcode/PIN/pattern prompt is shown
/// instead of a refusal; a failed or cancelled prompt denies access.
library;

import 'package:local_auth/local_auth.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart'
    show LocalAuthException;

abstract interface class AuthService {
  /// Prompts the user for biometric-or-device-credential authentication.
  /// Returns `true` only on explicit success; returns `false` for a denied,
  /// failed, or cancelled attempt, and for any platform error — this
  /// service NEVER throws to its caller, so a caller can treat "not true"
  /// as "do not reveal/use the seed" without a try/catch of its own.
  Future<bool> authenticate();

  /// Whether this device has ANY hardware wrap available at all (biometric
  /// enrolled OR a device passcode/PIN/pattern set) — i.e. whether
  /// [authenticate] would ever be able to show a real prompt.
  ///
  /// **Why this exists (vault-secure-storage-redesign PR7)**: `vault-unlock`
  /// spec's "Hybrid Two-Factor Unlock, PIN Always Mandatory" requirement —
  /// "Hardware wrap unavailable -> PIN-only still functions, never refuses
  /// to run". A device with neither biometrics nor a passcode configured is
  /// the genuine "no hardware wrap" case (design.md's "signing" flow:
  /// "AuthService.authenticate() (hardware wrap, skipped if unavailable)").
  /// Without this capability check, [authenticate] returning `false` for
  /// that device would be indistinguishable from a real user denial and
  /// would incorrectly lock such a device out of signing forever, even
  /// though the PIN alone is supposed to be sufficient. Never throws —
  /// mirrors [authenticate]'s own never-throws convention.
  Future<bool> isSupported();

  /// The single [BiometricKind] to represent for icon/copy purposes (e.g.
  /// the app-unlock retry key's fingerprint-vs-Face-ID icon), derived from
  /// `local_auth`'s `getAvailableBiometrics()`.
  ///
  /// **Never throws** — mirrors [authenticate] and [isSupported]'s
  /// never-throws convention; any platform error maps to
  /// [BiometricKind.none].
  ///
  /// Design.md's D4 precedence when multiple biometrics are enrolled:
  /// `face > fingerprint > iris`. Android's modality-less `strong`/`weak`
  /// (Class 3 / Class 2, reported without a specific modality) both map to
  /// [BiometricKind.fingerprint]. An empty list (no biometrics enrolled)
  /// maps to [BiometricKind.none].
  Future<BiometricKind> availableBiometric();
}

/// The biometric modality to represent for UI purposes (icon, copy).
///
/// Deliberately coarser than `local_auth`'s own `BiometricType` — this app
/// only ever needs to pick ONE icon to show, never the full enrolled set.
enum BiometricKind {
  /// No biometric enrolled, unsupported, or the platform query failed.
  none,

  /// Fingerprint sensor (or Android's modality-less strong/weak class).
  fingerprint,

  /// Face authentication (e.g. Face ID).
  face,

  /// Iris authentication.
  iris,
}

/// [AuthService] implementation backed by `local_auth`.
///
/// `biometricOnly: false` is the locked configuration: it yields the OS
/// biometric-**or**-device-credential prompt, satisfying the passcode
/// fallback requirement (design.md's "Biometric gate" section).
/// `stickyAuth: true` keeps the auth request alive across a transient
/// app-backgrounding blip (e.g. an incoming call) instead of silently
/// failing it.
///
/// **Unverified without a physical device**: the actual OS biometric/
/// passcode UI and hardware interaction cannot be exercised in this
/// sandboxed environment. This class is exercised in tests only against
/// `local_auth`'s own `LocalAuthPlatform.instance` test seam (see
/// `test/core/security/auth_service_test.dart`), which validates our
/// option-passing and error-to-`false` mapping but NOT the real platform
/// channel / native biometric prompt.
class LocalAuthAuthService implements AuthService {
  static const _defaultReason = 'Authenticate to access your vault';

  final LocalAuthentication _localAuth;
  final String localizedReason;

  LocalAuthAuthService({
    LocalAuthentication? localAuth,
    this.localizedReason = _defaultReason,
  }) : _localAuth = localAuth ?? LocalAuthentication();

  @override
  Future<bool> authenticate() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } on LocalAuthException {
      return false;
    } on Exception {
      return false;
    }
  }

  @override
  Future<bool> isSupported() async {
    try {
      return await _localAuth.isDeviceSupported();
    } on LocalAuthException {
      return false;
    } on Exception {
      return false;
    }
  }

  @override
  Future<BiometricKind> availableBiometric() async {
    List<BiometricType> enrolled;
    try {
      enrolled = await _localAuth.getAvailableBiometrics();
    } on LocalAuthException {
      return BiometricKind.none;
    } on Exception {
      return BiometricKind.none;
    }

    if (enrolled.contains(BiometricType.face)) {
      return BiometricKind.face;
    }
    if (enrolled.contains(BiometricType.fingerprint) ||
        enrolled.contains(BiometricType.strong) ||
        enrolled.contains(BiometricType.weak)) {
      return BiometricKind.fingerprint;
    }
    if (enrolled.contains(BiometricType.iris)) {
      return BiometricKind.iris;
    }
    return BiometricKind.none;
  }
}
