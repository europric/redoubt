/// `flutter_secure_storage`-backed [PublicAccountCache] implementation.
///
/// **hexagonal-architecture-refactor PR2**: moved from
/// `lib/core/security/public_account_cache.dart` to `features/account/
/// data/` alongside its port (see `../domain/public_account_cache.dart`'s
/// doc comment for the boundary-fix rationale). This move also extracts
/// D11's JSON encode/decode into `cached_account_json.dart` — [read]
/// hands `jsonDecode`'s raw result straight to [cachedAccountFromJson]
/// without casting it first, so [read] contains zero inline `as Map`/`as
/// String` decode-cast expressions; every decode-cast expression for this
/// data shape, including the `Map<String, dynamic>` cast on the decoded
/// root value, lives in [cachedAccountFromJson] (`architecture-boundaries`
/// spec's "JSON-Decode Casts Are Extracted Into A Dedicated Mapper"
/// requirement — see that function's doc comment for the correction note
/// on a prior revision that left this one root cast inline in [read]).
/// Storage key, options, and behavior are byte-for-byte unchanged.
///
/// **Design decision (design.md's "Public account cache lives in
/// `flutter_secure_storage` under its own key, read undecorated")**: this
/// is a STRICTLY-STRONGER deviation from the proposal's "unencrypted"
/// wording, not a weaker one. The requirement is *unlock-free*, not
/// *deliberately plaintext* — `flutter_secure_storage` reads cost only a
/// few ms and never prompt for biometrics/PIN, so this class uses the same
/// underlying OS keystore/keychain as `FlutterSecureSeedRepository` but
/// under its own key (`vault.account.public.v1`, distinct from
/// `vault.seed.entropy`) and WITHOUT the `AuthenticatedSeedRepository`
/// decorator — there is no auth gate anywhere in this class, by
/// construction: it has no dependency on `auth_service.dart` at all.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/account_derivation_service.dart';
import '../domain/eth_account.dart';
import '../domain/public_account_cache.dart';
import 'cached_account_json.dart';

class FlutterPublicAccountCache implements PublicAccountCache {
  static const _key = 'vault.account.public.v1';

  // Same underlying keystore/keychain configuration as
  // `FlutterSecureSeedRepository` — this class reads/writes a DIFFERENT
  // key (`vault.account.public.v1`, never `vault.seed.entropy`) and is
  // never wrapped by `AuthenticatedSeedRepository`, which is what makes it
  // unlock-free (see this file's own doc comment).
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

  const FlutterPublicAccountCache({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  @override
  Future<void> write({
    required EthAccount account,
    required String derivationPath,
    required AccountPairingKey pairing,
  }) => _storage.write(
    key: _key,
    value: jsonEncode(
      cachedAccountToJson(
        CachedAccount(
          account: account,
          derivationPath: derivationPath,
          pairing: pairing,
        ),
      ),
    ),
  );

  @override
  Future<CachedAccount?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;

    return cachedAccountFromJson(jsonDecode(raw));
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
