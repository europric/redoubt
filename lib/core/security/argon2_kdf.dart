/// Argon2id KEK (key-encryption-key) derivation — design.md's "Argon2id
/// parameters" decision.
///
/// **Library choice (vault-secure-storage-redesign PR4, task 5.1)**:
/// `package:cryptography`'s `Argon2id`. Its output was verified against the
/// published RFC 9106 Appendix A Argon2id known-answer-test vector BEFORE
/// this file wired it into production code (see
/// `test/core/security/argon2_kdf_test.dart`'s "RFC 9106 KAT" group and this
/// change's apply-progress record) — the byte-for-byte match meant the
/// named fallback (`pointycastle`) was never needed.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;

/// Argon2id cost + salt parameters for one vault. Field names mirror RFC
/// 9106 (`m` = memory in KiB, `t` = iterations, `p` = parallelism) and are
/// exactly what gets serialized into `VaultBlobHeader.{memoryKiB,
/// iterations, parallelism}` (`vault_blob.dart`, PR3) — design.md's escape
/// hatch: these values live per-vault inside the AD-covered blob header,
/// never hardcoded into a format-version bump.
class Argon2Params {
  const Argon2Params({
    required this.m,
    required this.t,
    required this.p,
    required this.salt,
  });

  /// Memory cost, in KiB — `cryptography`'s `Argon2id.memory` unit.
  final int m;

  /// Number of iterations (time cost).
  final int t;

  /// Degree of parallelism (lanes). Design.md ships `p=1`: `cryptography`'s
  /// Argon2id is pure Dart/single-isolate, so extra lanes cost identical
  /// wall-clock work with zero speedup on this stack.
  final int p;

  /// Per-vault random salt. 16 bytes for real vaults.
  final Uint8List salt;

  /// Returns a copy of these cost parameters (`m`/`t`/`p` unchanged) with
  /// [newSalt] substituted. Used to combine [kDefaultArgon2Params] /
  /// [kOwaspFloorArgon2Params]'s placeholder-salt templates with a freshly
  /// generated per-vault salt at seal time.
  Argon2Params withSalt(Uint8List newSalt) =>
      Argon2Params(m: m, t: t, p: p, salt: newSalt);
}

/// Ship default (design.md's "Argon2id parameters" decision): RFC 9106
/// SECOND RECOMMENDED shape — `m=64 MiB, t=3` — with `p` reduced from RFC's
/// 4 to 1.
///
/// **`salt` here is an empty placeholder, not a usable salt.** This
/// constant carries only the cost parameters. Real vaults MUST call
/// [Argon2Params.withSalt] with a freshly generated random 16-byte salt at
/// seal time; never derive a real KEK directly from this placeholder.
final Argon2Params kDefaultArgon2Params = Argon2Params(
  m: 64 * 1024,
  t: 3,
  p: 1,
  salt: Uint8List(0),
);

/// OWASP mobile floor (design.md) — used only if physical-device
/// benchmarking (Phase 9, blocking, out of scope for this PR) forces a
/// step-down from [kDefaultArgon2Params]. Never the shipped default on its
/// own. Same placeholder-salt caveat as [kDefaultArgon2Params] applies.
final Argon2Params kOwaspFloorArgon2Params = Argon2Params(
  m: 19 * 1024,
  t: 2,
  p: 1,
  salt: Uint8List(0),
);

/// Derives a KEK from a PIN's bytes via Argon2id. Pure key-derivation only —
/// no AEAD, no blob I/O (that is `vault_cipher.dart`'s job). Callers are
/// responsible for zeroizing both [password] and the returned KEK once
/// done, matching this codebase's existing zeroization convention
/// (`EthTransactionSigner.sign()`, `SecureSeedRepository.readEntropy()`).
abstract final class Argon2Kdf {
  /// [optionalSecret]/[associatedData] are RFC 9106's optional Argon2
  /// inputs. Real vault KEK derivation never uses them (left at their empty
  /// defaults); they exist on this API only so
  /// `test/core/security/argon2_kdf_test.dart`'s RFC 9106 Appendix A KAT —
  /// which exercises all four Argon2 inputs — can run through this exact
  /// production entry point rather than calling `package:cryptography`
  /// directly.
  static Future<Uint8List> derive({
    required Uint8List password,
    required Argon2Params params,
    int hashLength = 32,
    List<int> optionalSecret = const [],
    List<int> associatedData = const [],
  }) async {
    final algorithm = crypto.Argon2id(
      parallelism: params.p,
      memory: params.m,
      iterations: params.t,
      hashLength: hashLength,
    );
    final secretKey = await algorithm.deriveKey(
      secretKey: crypto.SecretKey(password),
      nonce: params.salt,
      optionalSecret: optionalSecret,
      associatedData: associatedData,
    );
    final bytes = await secretKey.extractBytes();
    return Uint8List.fromList(bytes);
  }
}
