/// The storage I/O seam for the vault's NEW `vault.seed.v1` key: the raw,
/// AEAD-sealed [VaultBlob] bytes produced by `VaultCipher.seal` — never the
/// legacy plaintext-hex entropy (`vault.seed.entropy`, see
/// [SecureSeedRepository], which still owns that key's legacy cleanup via
/// its existing `deleteVault()`).
///
/// **Pure storage plumbing only** (vault-secure-storage-redesign PR7): no
/// KDF, no AEAD, no PIN handling — that is entirely `vault_cipher.dart`'s
/// job. This class only knows how to move opaque bytes in and out of
/// `flutter_secure_storage` under one key, base64url-encoding at the
/// storage boundary exactly like `VaultBlob.encode`/`decode`'s own
/// convention (`flutter_secure_storage` only accepts/returns `String`
/// values).
///
/// **Ungated, by design** — same reasoning as `FlutterPublicAccountCache`/
/// `FlutterUnlockThrottle`/`FlutterVaultStateProbe`: this class has no
/// dependency on `AuthenticatedSeedRepository`/`AuthService` at all. The
/// PIN itself (via `VaultCipher.open`) is what actually protects the
/// plaintext; the hardware wrap (when available) is layered on top as an
/// explicit step in the signing flow (`EthTransactionSigner.sign`), not by
/// gating this storage read.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The fakeable boundary over the sealed vault blob's raw storage.
abstract interface class SealedVaultRepository {
  /// Persists [blob] (the exact bytes `VaultCipher.seal` returned) under the
  /// `vault.seed.v1` key. Overwrites any previously stored blob.
  Future<void> writeBlob(Uint8List blob);

  /// Reads the stored sealed-blob bytes, or `null` if nothing has been
  /// written yet.
  Future<Uint8List?> readBlob();

  /// Explicit, user-initiated wipe of the `vault.seed.v1` key. Idempotent —
  /// a no-op if nothing was ever written. Part of `account-deletion`'s
  /// ordered wipe (design.md D1); the sole intended production caller is
  /// `VaultResetController.confirmReset()`.
  ///
  /// **NEVER call from an app-lifecycle/background/terminate callback** —
  /// same "no lifecycle-triggered deletion" invariant as the legacy
  /// `SecureSeedRepository` wipe method.
  Future<void> deleteBlob();
}

class FlutterSealedVaultRepository implements SealedVaultRepository {
  static const _key = 'vault.seed.v1';

  // Same underlying keystore/keychain configuration as every other class in
  // this file's family (`FlutterSecureSeedRepository`,
  // `FlutterPublicAccountCache`, `FlutterUnlockThrottle`,
  // `FlutterVaultStateProbe`) — each owns its own key and its own
  // `FlutterSecureStorage` instance, per this codebase's established
  // convention.
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

  const FlutterSealedVaultRepository({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  @override
  Future<void> writeBlob(Uint8List blob) =>
      _storage.write(key: _key, value: base64Url.encode(blob));

  @override
  Future<Uint8List?> readBlob() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return base64Url.decode(raw);
  }

  @override
  Future<void> deleteBlob() => _storage.delete(key: _key);
}
