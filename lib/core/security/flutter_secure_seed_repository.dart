/// [SecureSeedRepository] implementation backed by `flutter_secure_storage`
/// (iOS Keychain / Android Keystore).
///
/// Configuration is per design.md's "Secure Storage Design" section, adapted
/// for `flutter_secure_storage` v11 (the v10-deprecated `RSA_ECB_PKCS1Padding`
/// key cipher and the Jetpack-Security-backed `encryptedSharedPreferences`
/// flag were both removed upstream in v11 — see CHANGELOG.md):
/// - Android: `keyCipherAlgorithm: RSA_ECB_OAEPwithSHA_256andMGF1Padding`
///   (the current default; wraps the AES key), `storageCipherAlgorithm:
///   AES_GCM_NoPadding`, `resetOnError: false`.
///   `resetOnError: false` is mandatory — a decrypt error must surface, never
///   silently wipe irreplaceable seed material.
/// - iOS: `accessibility: KeychainAccessibility.unlocked_this_device`
///   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) — blocks iCloud
///   Keychain sync and restore-to-another-device.
///
/// **Unverified without a physical device**: the actual Keystore/Keychain
/// read/write/decrypt-error behavior cannot be exercised in this sandboxed
/// environment (no emulator/device). This class is implemented faithfully
/// per design.md and is exercised in tests only against
/// `flutter_secure_storage`'s own in-memory `TestFlutterSecureStoragePlatform`
/// fake (see `test/core/security/secure_seed_repository_test.dart`), which
/// validates our wrapper logic (key name, null handling, delete semantics)
/// but NOT the real native encryption path. See the PR3 manual device
/// checklist in `tasks.md` / apply-progress for what must be verified before
/// this is trusted on a real phone.
///
/// **`Uint8List` migration (vault-secure-storage-redesign PR1)**: the
/// [SecureSeedRepository] interface speaks `Uint8List`, but
/// `flutter_secure_storage` only accepts/returns `String` values — this
/// class is the ONE place that hex-encodes on write and hex-decodes on
/// read. The bytes actually persisted in the backing store are byte-for-
/// byte unchanged by this migration (still the plain hex string under the
/// same key), which is what makes this slice independently revertible.
library;

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../bytes/hex.dart';
import 'secure_seed_repository.dart';

class FlutterSecureSeedRepository implements SecureSeedRepository {
  static const _entropyKey = 'vault.seed.entropy';

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

  const FlutterSecureSeedRepository({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage;

  @override
  Future<void> writeEntropy(Uint8List entropy) => _storage.write(
        key: _entropyKey,
        value: hexEncode(entropy),
      );

  @override
  Future<Uint8List?> readEntropy() async {
    final hex = await _storage.read(key: _entropyKey);
    if (hex == null) return null;
    return hexDecode(hex);
  }

  @override
  Future<bool> hasSeed() => _storage.containsKey(key: _entropyKey);

  @override
  Future<void> deleteVault() => _storage.delete(key: _entropyKey);
}
