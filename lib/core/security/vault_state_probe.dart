/// Storage-backed [VaultState] bootstrap probe (design.md's "Old-format
/// detection" section) — the ONLY thing `main.dart` calls before `runApp`.
///
/// **Scope of this PR (vault-secure-storage-redesign PR6, Phase 7)**: this
/// class is pure key-presence + header-parse, exactly like PR3's pure
/// `detectVaultState(...)` function it wraps — it deliberately does NOT
/// decrypt, does NOT prompt biometrics, and does NOT prompt for a PIN. It
/// reads the SAME two storage keys `FlutterSecureSeedRepository`
/// (`vault.seed.entropy`) and the future `vault.seed.v1` writer (PR7) use,
/// but talks to `flutter_secure_storage` directly instead of going through
/// either of those higher-level abstractions — this is intentional key
/// SEPARATION probing (design.md), not value-sniffing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'vault_blob.dart';

/// The fakeable boundary over the bootstrap [VaultState] probe.
abstract interface class VaultStateProbe {
  /// Probes storage and returns the current [VaultState]. Never decrypts,
  /// never prompts for a PIN or biometric.
  Future<VaultState> probe();
}

class FlutterVaultStateProbe implements VaultStateProbe {
  /// `vault.seed.entropy` — the legacy-only key (see
  /// `FlutterSecureSeedRepository`). Never written again once the redesign
  /// is fully cut over (PR7), but as of this PR it is still the ONLY key any
  /// production writer ever populates.
  static const _legacyKey = 'vault.seed.entropy';

  /// `vault.seed.v1` — the new base64url vault blob key (design.md's
  /// storage-keys table). No production writer populates this key yet
  /// (that lands in PR7); reachable in tests only via a fixture that writes
  /// it directly.
  static const _v1Key = 'vault.seed.v1';

  // Same underlying keystore/keychain configuration as
  // `FlutterSecureSeedRepository`/`FlutterPublicAccountCache` — this class
  // reads both their keys but is never wrapped by
  // `AuthenticatedSeedRepository`: a presence/header-parse probe must run
  // with zero auth gate, exactly like `SecureSeedRepository.hasSeed()`
  // already does.
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

  const FlutterVaultStateProbe({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  @override
  Future<VaultState> probe() async {
    final legacyKeyPresent = await _storage.containsKey(key: _legacyKey);
    final rawV1 = await _storage.read(key: _v1Key);

    if (rawV1 == null) {
      return detectVaultState(
        legacyKeyPresent: legacyKeyPresent,
        v1Bytes: null,
      );
    }

    final Uint8List v1Bytes;
    try {
      v1Bytes = base64Url.decode(rawV1);
    } on FormatException {
      // Bad base64url is itself a malformed-blob case — never charges the
      // unlock throttle, never decrypts, same as `MalformedVaultBlobFailure`
      // would if `VaultBlob.decodeBytes` had gotten to see any bytes at all.
      return VaultState.unreadable;
    }

    return detectVaultState(
      legacyKeyPresent: legacyKeyPresent,
      v1Bytes: v1Bytes,
    );
  }
}
