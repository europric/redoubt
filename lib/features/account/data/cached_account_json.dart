/// D11's bidirectional JSON mapper for [CachedAccount] (hexagonal-
/// architecture-refactor PR2, "JSON-Decode Casts Are Extracted Into A
/// Dedicated Mapper" requirement).
///
/// Extracted out of `FlutterPublicAccountCache.read()`/`.write()`, which
/// previously duplicated the `version`/`address`/`derivationPath`/`pairing`
/// key names across both directions inline. [FlutterPublicAccountCache]
/// now delegates all encode/decode to [cachedAccountToJson]/
/// [cachedAccountFromJson] and keeps only `jsonEncode`/`jsonDecode` plus
/// storage I/O in its own body — zero behavior change, same key names, same
/// cast targets.
///
/// **Correction (sdd-verify FAIL finding)**: [cachedAccountFromJson] takes
/// `dynamic`, not `Map<String, dynamic>`, precisely so the `as Map<String,
/// dynamic>` cast on `jsonDecode`'s root result also lives here rather than
/// inline in `read()`. An earlier revision left that one root cast behind
/// in `read()` (`jsonDecode(raw) as Map<String, dynamic>`) while every
/// nested-field cast was already extracted — this function now owns every
/// decode-cast expression for this data shape, with zero remaining in
/// `read()`.
library;

import '../domain/account_derivation_service.dart';
import '../domain/eth_account.dart';
import '../domain/public_account_cache.dart';

const _version = 1;

/// Encodes [cachedAccount] into the exact map shape
/// `flutter_secure_storage`'s stored JSON has always used under the
/// `vault.account.public.v1` key.
Map<String, dynamic> cachedAccountToJson(CachedAccount cachedAccount) => {
  'version': _version,
  'address': cachedAccount.account.address,
  'derivationPath': cachedAccount.derivationPath,
  'pairing': {
    'publicKeyCompressed': cachedAccount.pairing.publicKeyCompressed,
    'chainCode': cachedAccount.pairing.chainCode,
    'sourceFingerprint': cachedAccount.pairing.sourceFingerprint,
    'parentFingerprint': cachedAccount.pairing.parentFingerprint,
    'depth': cachedAccount.pairing.depth,
    'pathIndexes': cachedAccount.pairing.pathIndexes,
  },
};

/// Decodes the raw `dynamic` value `jsonDecode` produces (or an equivalent
/// already-decoded value) back into a [CachedAccount]. Accepts `dynamic`
/// rather than `Map<String, dynamic>` so the caller (`FlutterPublicAccountCache.
/// read()`) can hand over `jsonDecode`'s result untouched -- this function,
/// not `read()`, owns the `as Map<String, dynamic>` cast on the decoded
/// root value, on top of the `as String`/`as int`/`.cast<int>()` casts on
/// its nested fields. The only place any inline decode-cast expression
/// lives for this data shape.
CachedAccount cachedAccountFromJson(dynamic json) {
  final map = json as Map<String, dynamic>;
  final pairingMap = map['pairing'] as Map<String, dynamic>;

  return CachedAccount(
    account: EthAccount(address: map['address'] as String),
    derivationPath: map['derivationPath'] as String,
    pairing: AccountPairingKey(
      publicKeyCompressed: (pairingMap['publicKeyCompressed'] as List)
          .cast<int>(),
      chainCode: (pairingMap['chainCode'] as List).cast<int>(),
      sourceFingerprint: pairingMap['sourceFingerprint'] as int,
      parentFingerprint: pairingMap['parentFingerprint'] as int,
      depth: pairingMap['depth'] as int,
      pathIndexes: (pairingMap['pathIndexes'] as List).cast<int>(),
    ),
  );
}
