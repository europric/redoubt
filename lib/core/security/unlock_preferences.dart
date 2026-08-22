/// Persists two independent, absent-means-false boolean flags governing
/// onboarding/app-unlock UX (biometric-unlock-onboarding design.md's
/// Technical Approach: "a new `UnlockPreferences` storage seam persists two
/// independent flags, following this codebase's one-class-one-key
/// convention (`FlutterUnlockThrottle`, `FlutterSealedVaultRepository`)").
///
/// | Key | Meaning | Wiped on account deletion |
/// |---|---|---|
/// | `onboarding.intro.seen.v1` | Intro explainer already shown | No — design.md decision 5 |
/// | `vault.unlock.biometric.v1` | Biometric app-unlock opted in | Yes — `VaultResetController`'s ordered wipe |
///
/// **Built in PR3, ahead of its design.md-assigned PR4/task-4.1 slot**: both
/// `BiometricEnrollmentController.enable()` (task 3.2, this PR) and the
/// onboarding intro page (task 3.3, this PR) need a real, working flag seam
/// to satisfy their own scenarios — not a stub. Design.md specifies the
/// exact key names and absent-means-false semantics precisely enough to
/// build the genuine target file now (rather than a parallel/incompatible
/// mechanism); PR4's task 4.1 consumes this file as-is for
/// `AppUnlockController`/the redirect matrix, with nothing left to create.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class UnlockPreferences {
  /// Whether the onboarding intro explainer has already been shown.
  /// Absent (fresh install) reads as `false`.
  Future<bool> getIntroSeen();

  Future<void> setIntroSeen(bool value);

  /// Whether biometric app-unlock has been opted into (via
  /// `BiometricEnrollmentController.enable()`). Absent reads as `false`.
  Future<bool> getBiometricEnabled();

  Future<void> setBiometricEnabled(bool value);
}

class FlutterUnlockPreferences implements UnlockPreferences {
  static const _introSeenKey = 'onboarding.intro.seen.v1';
  static const _biometricEnabledKey = 'vault.unlock.biometric.v1';

  // Same underlying keystore/keychain configuration as
  // `FlutterUnlockThrottle`/`FlutterPublicAccountCache` — reads/writes its
  // own keys, never gated by `AuthenticatedSeedRepository` (these flags must
  // be readable/writable before any unlock has happened).
  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  final FlutterSecureStorage _storage;

  const FlutterUnlockPreferences({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  @override
  Future<bool> getIntroSeen() => _readFlag(_introSeenKey);

  @override
  Future<void> setIntroSeen(bool value) => _writeFlag(_introSeenKey, value);

  @override
  Future<bool> getBiometricEnabled() => _readFlag(_biometricEnabledKey);

  @override
  Future<void> setBiometricEnabled(bool value) =>
      _writeFlag(_biometricEnabledKey, value);

  Future<bool> _readFlag(String key) async =>
      (await _storage.read(key: key)) == 'true';

  Future<void> _writeFlag(String key, bool value) =>
      _storage.write(key: key, value: value ? 'true' : 'false');
}
