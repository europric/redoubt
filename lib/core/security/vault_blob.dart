/// Versioned vault blob v1 header/layout codec — design.md's "Vault blob
/// v1 layout (binary, base64Url into the flutter_secure_storage value)"
/// section.
///
/// **Scope of this PR (vault-secure-storage-redesign PR3, Phase 4)**: this
/// file owns ONLY the byte layout — encode/decode of the header, exposing
/// the header bytes verbatim as the AEAD associated data, and a pure
/// byte-level [VaultState] detection scaffold. It deliberately does NOT
/// implement Argon2id/KDF or any production AEAD seal/open — that lands in
/// PR4's `argon2_kdf.dart` + `vault_cipher.dart`, wired through the codec
/// exposed here. [VaultState] is not wired into app startup/router yet
/// either (that is PR6/Phase 7); this is byte-level scaffolding only.
///
/// **Layout** (see design.md for the authoritative table):
/// ```
/// off len field
///  0   1  version
///  1   1  kdf id
///  2   1  aead id
///  3   1  parallelism p (uint8)
///  4   4  memory KiB m (uint32 BE)
///  8   4  iterations t (uint32 BE)
/// 12   1  salt len
/// 13   N  salt
/// 13+N 1  nonce len
/// 14+N M  nonce
/// 14+N+M .. ciphertext || 16-byte tag
/// ```
/// **Bytes `0 .. (14+N+M-1)` are the AEAD associated data** — this is the
/// layout's most important property (design.md): tampering with ANY header
/// byte (including a downgraded `m`/`t`) must fail the AEAD tag check
/// instead of silently weakening the KDF or the vault's read path.
///
/// **Wrong PIN vs corrupt blob are different failures** (design.md
/// decision): a header that fails to *parse* at all (truncated, garbage,
/// bad base64) throws [MalformedVaultBlobFailure]; a header that parses but
/// carries an unrecognized version byte throws
/// [UnsupportedVaultVersionFailure]. Neither of these charges the unlock
/// throttle (that only happens for a parseable header whose AEAD tag check
/// fails against a *correct* PIN attempt — PR4's `VaultCipher`/`WrongPinFailure`).
library;

import 'dart:convert';
import 'dart:typed_data';

/// v1 blob format version byte.
const int kVaultBlobVersion1 = 0x01;

/// KDF identifiers reserved in the v1 header.
const int kKdfIdArgon2id = 0x01;

/// AEAD identifiers reserved in the v1 header.
const int kAeadIdXChaCha20Poly1305 = 0x01;
const int kAeadIdAes256Gcm = 0x02;

/// Offset of the salt-length byte; everything before it is fixed-size.
const int _kFixedPrefixLen = 13;

/// Thrown when raw bytes (or a base64url string) cannot be parsed as a v1
/// vault blob header at all: too short, truncated mid-field, or invalid
/// base64url. Never charges the unlock throttle (design.md).
class MalformedVaultBlobFailure implements Exception {
  const MalformedVaultBlobFailure(this.message);

  final String message;

  @override
  String toString() => 'MalformedVaultBlobFailure: $message';
}

/// Thrown when a header parses structurally but its version byte is not
/// one this codec recognizes. Never charges the unlock throttle
/// (design.md) — this is a format issue, not a wrong-PIN attempt.
class UnsupportedVaultVersionFailure implements Exception {
  const UnsupportedVaultVersionFailure(this.versionByte);

  final int versionByte;

  @override
  String toString() =>
      'UnsupportedVaultVersionFailure: unrecognized version byte '
      '0x${versionByte.toRadixString(16).padLeft(2, '0')}';
}

/// The parsed in-memory shape of a v1 vault blob header. KDF cost params
/// ([parallelism], [memoryKiB], [iterations]) travel inside the header so
/// they are covered by the AD binding — see this file's doc comment.
class VaultBlobHeader {
  const VaultBlobHeader({
    required this.version,
    required this.kdfId,
    required this.aeadId,
    required this.parallelism,
    required this.memoryKiB,
    required this.iterations,
    required this.salt,
    required this.nonce,
  });

  final int version;
  final int kdfId;
  final int aeadId;
  final int parallelism;
  final int memoryKiB;
  final int iterations;
  final Uint8List salt;
  final Uint8List nonce;
}

/// Result of parsing a raw vault blob: the header, the exact header bytes
/// (== the AEAD associated data), and the trailing ciphertext||tag bytes.
class ParsedVaultBlob {
  const ParsedVaultBlob({
    required this.header,
    required this.associatedData,
    required this.cipherTextWithTag,
  });

  final VaultBlobHeader header;
  final Uint8List associatedData;
  final Uint8List cipherTextWithTag;
}

/// Byte-level vault state, probed via key presence + header parse ONLY —
/// no decryption, no PIN, no biometric (design.md's "Old-format detection"
/// section). Not wired into app startup/router in this PR (PR6/Phase 7).
enum VaultState {
  /// Neither the v1 key nor the legacy entropy key exists.
  none,

  /// Only the legacy plaintext-hex entropy key exists.
  legacy,

  /// The v1 key exists and its header parses with a known version.
  current,

  /// The v1 key exists but its bytes do not parse as a valid v1 header
  /// (malformed or an unrecognized version).
  unreadable,
}

/// The v1 vault blob header/layout codec. Pure functions only — no I/O, no
/// crypto.
abstract final class VaultBlob {
  /// Encodes just the header portion of [header]. These exact bytes are the
  /// AEAD associated data (see this file's doc comment).
  static Uint8List encodeHeader(VaultBlobHeader header) {
    final builder = BytesBuilder(copy: false);
    builder.addByte(header.version);
    builder.addByte(header.kdfId);
    builder.addByte(header.aeadId);
    builder.addByte(header.parallelism);
    builder.add(_uint32BE(header.memoryKiB));
    builder.add(_uint32BE(header.iterations));
    builder.addByte(header.salt.length);
    builder.add(header.salt);
    builder.addByte(header.nonce.length);
    builder.add(header.nonce);
    return builder.toBytes();
  }

  /// Encodes [header] followed by [cipherTextWithTag] into the full v1
  /// binary blob layout.
  static Uint8List encodeBytes({
    required VaultBlobHeader header,
    required Uint8List cipherTextWithTag,
  }) {
    final headerBytes = encodeHeader(header);
    final out = Uint8List(headerBytes.length + cipherTextWithTag.length);
    out.setRange(0, headerBytes.length, headerBytes);
    out.setRange(headerBytes.length, out.length, cipherTextWithTag);
    return out;
  }

  /// base64url convenience wrapper over [encodeBytes] — the exact shape
  /// written into `flutter_secure_storage`'s string-only value.
  static String encode({
    required VaultBlobHeader header,
    required Uint8List cipherTextWithTag,
  }) => base64Url.encode(
    encodeBytes(header: header, cipherTextWithTag: cipherTextWithTag),
  );

  /// Parses raw bytes into a header, its associated-data bytes, and the
  /// trailing ciphertext||tag. Throws [MalformedVaultBlobFailure] on
  /// truncated/garbage input and [UnsupportedVaultVersionFailure] on an
  /// otherwise well-formed header with an unrecognized version byte.
  static ParsedVaultBlob decodeBytes(Uint8List bytes) {
    if (bytes.length < _kFixedPrefixLen) {
      throw MalformedVaultBlobFailure(
        'blob is ${bytes.length} bytes, shorter than the '
        '$_kFixedPrefixLen-byte fixed header prefix',
      );
    }

    final version = bytes[0];
    if (version != kVaultBlobVersion1) {
      throw UnsupportedVaultVersionFailure(version);
    }

    final kdfId = bytes[1];
    final aeadId = bytes[2];
    final parallelism = bytes[3];
    final memoryKiB = _readUint32BE(bytes, 4);
    final iterations = _readUint32BE(bytes, 8);

    final saltLen = bytes[12];
    const saltStart = _kFixedPrefixLen;
    final saltEnd = saltStart + saltLen;
    if (bytes.length < saltEnd + 1) {
      throw MalformedVaultBlobFailure(
        'blob truncated: expected $saltLen-byte salt starting at offset '
        '$saltStart plus a nonce-length byte, only ${bytes.length} bytes '
        'present',
      );
    }
    final salt = Uint8List.fromList(bytes.sublist(saltStart, saltEnd));

    final nonceLen = bytes[saltEnd];
    final nonceStart = saltEnd + 1;
    final nonceEnd = nonceStart + nonceLen;
    if (bytes.length < nonceEnd) {
      throw MalformedVaultBlobFailure(
        'blob truncated: expected $nonceLen-byte nonce starting at offset '
        '$nonceStart, only ${bytes.length} bytes present',
      );
    }
    final nonce = Uint8List.fromList(bytes.sublist(nonceStart, nonceEnd));

    final header = VaultBlobHeader(
      version: version,
      kdfId: kdfId,
      aeadId: aeadId,
      parallelism: parallelism,
      memoryKiB: memoryKiB,
      iterations: iterations,
      salt: salt,
      nonce: nonce,
    );

    return ParsedVaultBlob(
      header: header,
      associatedData: Uint8List.fromList(bytes.sublist(0, nonceEnd)),
      cipherTextWithTag: Uint8List.fromList(bytes.sublist(nonceEnd)),
    );
  }

  /// base64url convenience wrapper over [decodeBytes]. A [FormatException]
  /// from an invalid base64url string is converted to
  /// [MalformedVaultBlobFailure].
  static ParsedVaultBlob decode(String base64UrlBlob) {
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64UrlBlob);
    } on FormatException catch (e) {
      throw MalformedVaultBlobFailure('invalid base64url: ${e.message}');
    }
    return decodeBytes(bytes);
  }
}

/// Byte-level [VaultState] probe (design.md's "Old-format detection"):
/// v1 key present -> parse header -> known version = [VaultState.current],
/// else [VaultState.unreadable]; else legacy key present =
/// [VaultState.legacy]; else [VaultState.none]. Pure function — no storage
/// I/O, no decrypt, no PIN, no biometric.
VaultState detectVaultState({
  required bool legacyKeyPresent,
  required Uint8List? v1Bytes,
}) {
  if (v1Bytes != null) {
    try {
      VaultBlob.decodeBytes(v1Bytes);
      return VaultState.current;
    } on MalformedVaultBlobFailure {
      return VaultState.unreadable;
    } on UnsupportedVaultVersionFailure {
      return VaultState.unreadable;
    }
  }
  return legacyKeyPresent ? VaultState.legacy : VaultState.none;
}

Uint8List _uint32BE(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xFF
  ..[1] = (value >> 16) & 0xFF
  ..[2] = (value >> 8) & 0xFF
  ..[3] = value & 0xFF;

int _readUint32BE(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
