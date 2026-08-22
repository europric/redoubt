/// UUID CBOR codec — CBOR tag 37, per BCR-2020-006
/// (github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-006-urtypes.md)
/// and used by Keystone's `bc-ur-registry` for `eth-sign-request` /
/// `eth-signature` request-ids.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The CBOR tag for a raw UUID byte string.
const int uuidCborTag = 37;

/// Thrown when a UUID CBOR value fails to decode: wrong CBOR major type,
/// missing tag 37, or a byte length other than 16.
class UuidCborException implements Exception {
  final String message;
  UuidCborException(this.message);

  @override
  String toString() => 'UuidCborException: $message';
}

/// Wraps 16 raw [uuidBytes] as a tag-37 CBOR byte string [CborValue] —
/// nestable inside other registry maps (e.g. `eth-sign-request`'s
/// `request-id` field).
CborValue uuidToCborValue(List<int> uuidBytes) {
  if (uuidBytes.length != 16) {
    throw ArgumentError.value(
      uuidBytes.length,
      'uuidBytes.length',
      'a UUID must be exactly 16 bytes',
    );
  }
  return CborBytes(uuidBytes, tags: [uuidCborTag]);
}

/// Extracts the 16 raw UUID bytes from a decoded [value] that must be a
/// tag-37 CBOR byte string.
Uint8List uuidFromCborValue(CborValue value) {
  if (value is! CborBytes) {
    throw UuidCborException('expected a CBOR byte string, got ${value.runtimeType}');
  }
  if (!value.tags.contains(uuidCborTag)) {
    throw UuidCborException('missing CBOR tag $uuidCborTag, got tags ${value.tags}');
  }
  if (value.bytes.length != 16) {
    throw UuidCborException('uuid must be 16 bytes, got ${value.bytes.length}');
  }
  return Uint8List.fromList(value.bytes);
}

/// Encodes [uuidBytes] as standalone tag-37 CBOR bytes.
Uint8List encodeUuidCbor(List<int> uuidBytes) =>
    Uint8List.fromList(cbor.encode(uuidToCborValue(uuidBytes)));

/// Decodes standalone tag-37 CBOR [data] back into 16 raw UUID bytes.
///
/// Throws [UuidCborException] for malformed input (untrusted-input boundary:
/// QR/UR payloads are attacker-controllable) — never lets a decode problem
/// surface as an uncaught exception type.
Uint8List decodeUuidCbor(List<int> data) {
  final CborValue value;
  try {
    value = cbor.decode(data);
  } catch (e) {
    throw UuidCborException('invalid CBOR: $e');
  }
  return uuidFromCborValue(value);
}
