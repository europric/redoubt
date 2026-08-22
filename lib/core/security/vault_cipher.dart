/// Real Argon2id + AEAD seal/open wired through `vault_blob.dart` (PR3)'s
/// versioned header codec + `argon2_kdf.dart` (this PR)'s KEK derivation —
/// design.md's "Vault blob v1 layout" `VaultCipher.seal`/`open` contract.
///
/// **Wrong PIN vs corrupt blob are different failures** (design.md
/// decision, already implemented for the header by PR3's `vault_blob.dart`
/// via [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure]): a
/// header that parses with a known version but whose AEAD tag check fails
/// throws [WrongPinFailure] — the only failure category this file adds.
/// [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure] propagate
/// unchanged from [VaultBlob.decodeBytes] — neither charges the unlock
/// throttle (that decision lives in the not-yet-built `UnlockThrottle`,
/// PR5).
///
/// **Zeroization** (design.md: "Both zeroize the KEK and intermediates in
/// finally"): replicates `EthTransactionSigner.sign()`'s convention —
/// sensitive buffers are zero-filled via `Uint8List.fillRange(0, len, 0)`
/// inside a `finally` block that runs whether the method returns normally
/// or throws. `open()` additionally copies the AEAD library's raw decrypted
/// buffer into a fresh `Uint8List` before returning, so the finally block
/// can zero that internal intermediate WITHOUT corrupting the value handed
/// back to the caller (the caller still owns zeroizing the returned
/// plaintext once done, per `SecureSeedRepository.readEntropy()`'s existing
/// convention). PIN bytes are caller-owned — neither `seal()` nor `open()`
/// mutates the `pin` argument.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart' show compute;
import 'package:meta/meta.dart';

import 'argon2_kdf.dart';
import 'vault_blob.dart';
import 'vault_plaintext.dart';

/// Thrown when a v1 blob header parses with a known version, but the AEAD
/// tag check fails against the supplied PIN. Distinct from
/// [MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure] (design.md's
/// "Wrong PIN and corrupt blob are different failures" decision) — this is
/// the only failure category charged against the unlock throttle.
class WrongPinFailure implements Exception {
  const WrongPinFailure();

  @override
  String toString() => 'WrongPinFailure: PIN did not open this vault';
}

/// Length (in bytes) of every AEAD tag this codec uses — both
/// XChaCha20-Poly1305 and AES-256-GCM produce 16-byte Poly1305/GHASH tags.
const int _kTagLength = 16;

/// Seals/opens vault plaintext through the v1 blob format. Pure
/// crypto-wiring — no storage I/O (that is `VaultCommitService`/
/// `FlutterSecureSeedRepository`'s job, PR7).
abstract final class VaultCipher {
  /// **Test-only hook** (`@visibleForTesting`): exposes the last KEK buffer
  /// [seal]/[open] computed, captured by reference BEFORE the `finally`
  /// block zero-fills it in place — so a test can assert the SAME buffer
  /// is all-zero AFTER the call returns, proving the zeroization actually
  /// ran at runtime rather than merely asserting the word `fillRange`
  /// appears near `finally` in source. Never read by production code.
  @visibleForTesting
  static Uint8List? debugLastKek;

  /// **Test-only hook** (`@visibleForTesting`): exposes [open]'s raw
  /// AEAD-library decrypted buffer (the intermediate that gets zeroized in
  /// `open()`'s `finally` block) — distinct from the fresh copy `open()`
  /// actually returns to its caller. Never read by production code.
  @visibleForTesting
  static Uint8List? debugLastRawDecryptedIntermediate;

  /// Encrypts [plaintext] under a PIN-derived Argon2id KEK and returns the
  /// full encoded v1 blob (raw bytes — base64url encoding, if needed for a
  /// string-only storage API, is the caller's job via
  /// `VaultBlob.encode`-equivalent handling).
  ///
  /// Generates a fresh random 16-byte salt and an AEAD-appropriate random
  /// nonce (24 bytes for XChaCha20-Poly1305, 12 for AES-256-GCM) on every
  /// call — real vaults never reuse a salt/nonce pair.
  static Future<Uint8List> seal({
    required Uint8List plaintext,
    required Uint8List pin,
    Argon2Params? costParams,
    int aeadId = kAeadIdXChaCha20Poly1305,
  }) async {
    final params = costParams ?? kDefaultArgon2Params;
    final algorithm = _aeadAlgorithmFor(aeadId);
    final salt = _randomBytes(16);
    final nonce = _randomBytes(algorithm.nonceLength);

    final header = VaultBlobHeader(
      version: kVaultBlobVersion1,
      kdfId: kKdfIdArgon2id,
      aeadId: aeadId,
      parallelism: params.p,
      memoryKiB: params.m,
      iterations: params.t,
      salt: salt,
      nonce: nonce,
    );
    final headerBytes = VaultBlob.encodeHeader(header);

    Uint8List? kek;
    try {
      kek = await Argon2Kdf.derive(
        password: pin,
        params: params.withSalt(salt),
      );
      debugLastKek = kek;

      final secretBox = await algorithm.encrypt(
        plaintext,
        secretKey: crypto.SecretKey(kek),
        nonce: nonce,
        aad: headerBytes,
      );
      final cipherTextWithTag = Uint8List.fromList([
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);

      return VaultBlob.encodeBytes(
        header: header,
        cipherTextWithTag: cipherTextWithTag,
      );
    } finally {
      if (kek != null) {
        kek.fillRange(0, kek.length, 0);
      }
    }
  }

  /// Decrypts [blob] using a PIN-derived Argon2id KEK.
  ///
  /// Throws (unchanged, propagated from [VaultBlob.decodeBytes]):
  /// - [MalformedVaultBlobFailure] — truncated/garbage/bad-base64 input.
  /// - [UnsupportedVaultVersionFailure] — well-formed header, unknown
  ///   version byte.
  ///
  /// Throws (added by this file):
  /// - [WrongPinFailure] — well-formed, known-version header whose AEAD tag
  ///   check fails against [pin]. Never thrown for anything the header
  ///   itself failed to parse.
  static Future<Uint8List> open({
    required Uint8List blob,
    required Uint8List pin,
  }) async {
    final parsed = VaultBlob.decodeBytes(blob);

    if (parsed.header.kdfId != kKdfIdArgon2id) {
      throw MalformedVaultBlobFailure(
        'unrecognized kdf id '
        '0x${parsed.header.kdfId.toRadixString(16).padLeft(2, '0')}',
      );
    }
    final crypto.Cipher algorithm;
    try {
      algorithm = _aeadAlgorithmFor(parsed.header.aeadId);
    } on ArgumentError {
      throw MalformedVaultBlobFailure(
        'unrecognized aead id '
        '0x${parsed.header.aeadId.toRadixString(16).padLeft(2, '0')}',
      );
    }
    if (parsed.cipherTextWithTag.length < _kTagLength) {
      throw const MalformedVaultBlobFailure(
        'ciphertext shorter than the AEAD tag length',
      );
    }
    _requireSaneArgon2CostBounds(parsed.header);

    final tagStart = parsed.cipherTextWithTag.length - _kTagLength;
    final cipherText = parsed.cipherTextWithTag.sublist(0, tagStart);
    final tag = parsed.cipherTextWithTag.sublist(tagStart);

    Uint8List? kek;
    Uint8List? rawPlaintext;
    try {
      kek = await Argon2Kdf.derive(
        password: pin,
        params: Argon2Params(
          m: parsed.header.memoryKiB,
          t: parsed.header.iterations,
          p: parsed.header.parallelism,
          salt: parsed.header.salt,
        ),
      );
      debugLastKek = kek;

      final List<int> decrypted;
      try {
        decrypted = await algorithm.decrypt(
          crypto.SecretBox(
            cipherText,
            nonce: parsed.header.nonce,
            mac: crypto.Mac(tag),
          ),
          secretKey: crypto.SecretKey(kek),
          aad: parsed.associatedData,
        );
      } on crypto.SecretBoxAuthenticationError {
        throw const WrongPinFailure();
      }

      rawPlaintext = Uint8List.fromList(decrypted);
      debugLastRawDecryptedIntermediate = rawPlaintext;

      // Return a distinct copy — see this file's doc comment on why the
      // finally block below can safely zeroize [rawPlaintext] without
      // corrupting the value handed back to the caller.
      return Uint8List.fromList(rawPlaintext);
    } finally {
      if (kek != null) {
        kek.fillRange(0, kek.length, 0);
      }
      if (rawPlaintext != null) {
        rawPlaintext.fillRange(0, rawPlaintext.length, 0);
      }
    }
  }

  static crypto.Cipher _aeadAlgorithmFor(int aeadId) {
    switch (aeadId) {
      case kAeadIdXChaCha20Poly1305:
        return crypto.Xchacha20.poly1305Aead();
      case kAeadIdAes256Gcm:
        return crypto.AesGcm.with256bits();
      default:
        throw ArgumentError.value(aeadId, 'aeadId', 'unrecognized aead id');
    }
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Rejects Argon2id cost parameters outside a sane operating range before
  /// [Argon2Kdf.derive] ever runs. `memoryKiB`/`iterations` are
  /// attacker-controllable header bytes (bytes 4-11 of the AD-covered
  /// header) — without this guard, a single tampered byte can make
  /// `memoryKiB` claim several terabytes and exhaust device memory (an
  /// out-of-memory crash) instead of failing cleanly like every other
  /// header-tamper case. This is a format-sanity check, not a PIN check —
  /// it throws [MalformedVaultBlobFailure], matching the malformed-header
  /// case, and never charges the unlock throttle.
  static void _requireSaneArgon2CostBounds(VaultBlobHeader header) {
    const maxMemoryKiB =
        1024 * 1024; // 1 GiB — well above kDefaultArgon2Params.
    const maxIterations = 32;
    const maxParallelism = 8;
    if (header.memoryKiB < 8 || header.memoryKiB > maxMemoryKiB) {
      throw MalformedVaultBlobFailure(
        'memoryKiB ${header.memoryKiB} outside the sane range [8, '
        '$maxMemoryKiB]',
      );
    }
    if (header.iterations < 1 || header.iterations > maxIterations) {
      throw MalformedVaultBlobFailure(
        'iterations ${header.iterations} outside the sane range [1, '
        '$maxIterations]',
      );
    }
    if (header.parallelism < 1 || header.parallelism > maxParallelism) {
      throw MalformedVaultBlobFailure(
        'parallelism ${header.parallelism} outside the sane range [1, '
        '$maxParallelism]',
      );
    }
    if (header.memoryKiB < 8 * header.parallelism) {
      throw MalformedVaultBlobFailure(
        'memoryKiB ${header.memoryKiB} is smaller than 8 * parallelism '
        '(${header.parallelism})',
      );
    }
  }
}

/// Argument bundle for [_openSync] — [compute]'s callback takes exactly one
/// argument, and (mirroring `core/eth/bip39_seed.dart`'s convention) that
/// argument must be a plain, isolate-sendable value, never a closure.
class _OpenArgs {
  const _OpenArgs(this.blob, this.pin);

  final Uint8List blob;
  final Uint8List pin;
}

/// Plain top-level function (required by [compute] — must not be a closure,
/// instance method, or capture surrounding state) that runs
/// [VaultCipher.open] on whatever isolate [compute] schedules it on, and
/// then decodes the sealed-plaintext framing (design.md D6/D7) on the SAME
/// isolate hop — so [openVaultBlobInBackground] returns a `(Uint8List,
/// int)` record (entropy, language wire code), never a bare decrypted
/// buffer. `Uint8List`/`int` are provably isolate-sendable; a [VaultSecret]
/// instance itself is not risked crossing the isolate boundary (matches
/// `core/eth/bip39_seed.dart`'s `language.wireCode`-not-the-enum
/// convention).
Future<(Uint8List, int)> _openSync(_OpenArgs args) async {
  final plaintext = await VaultCipher.open(blob: args.blob, pin: args.pin);
  final secret = VaultPlaintext.decode(plaintext);
  return (secret.entropy, secret.languageWireCode);
}

/// Runs [VaultCipher.open] + [VaultPlaintext.decode] on a background
/// isolate via [compute] — mirrors `core/eth/bip39_seed.dart`'s
/// `deriveBip39SeedInBackground` pattern, for the same reason:
/// [VaultCipher.open] runs the same expensive Argon2id KDF that PBKDF2 seed
/// derivation does, and the signing flow (`EthTransactionSigner.sign`,
/// vault-secure-storage-redesign PR7) must never block the UI isolate's
/// event loop while it runs. Propagates
/// [WrongPinFailure]/[MalformedVaultBlobFailure]/[UnsupportedVaultVersionFailure]
/// (from [VaultCipher.open]) and [MalformedVaultPlaintextFailure] (from
/// [VaultPlaintext.decode]) unchanged (all are plain value classes with
/// only primitive fields, so they transfer across the isolate boundary
/// intact).
///
/// **Since Phase 2 (bip39-nfkd-normalization PR2, design.md D7)**: returns a
/// [VaultSecret], not a bare `Uint8List` — every consumer of an opened
/// vault therefore receives the language structurally, and it cannot be
/// dropped at one call site. Does NOT itself enforce design.md D8's loud
/// guard (an unrecognized wire code decodes into a [VaultSecret] without
/// throwing) — callers that must refuse to proceed call
/// [VaultSecret.requireLanguage] explicitly (`EthTransactionSigner.sign`,
/// `AppUnlockController.submitPin`, `RevealSeedController.reveal` — but
/// deliberately NOT `VaultResetController.confirmReset`, the wipe escape
/// hatch).
Future<VaultSecret> openVaultBlobInBackground({
  required Uint8List blob,
  required Uint8List pin,
}) async {
  final (entropy, languageWireCode) = await compute(
    _openSync,
    _OpenArgs(blob, pin),
  );
  return VaultSecret(entropy: entropy, languageWireCode: languageWireCode);
}
