/// Pure-Dart, dependency-free hex codec. Replaces the narrow
/// `BytesUtils.toHexString`/`fromHexString` use in
/// `FlutterSecureSeedRepository` (design.md D7) — byte-for-byte compatible
/// with `BytesUtils`'s default (lowercase, unprefixed) hex encoding.
library;

import 'dart:typed_data';

/// Encodes [bytes] as a lowercase, unprefixed hex string.
String hexEncode(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Decodes a hex string [hex] (case-insensitive, unprefixed) into raw bytes.
Uint8List hexDecode(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
