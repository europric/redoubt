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
///
/// Throws [FormatException] on odd-length input (#26) — an odd-length hex
/// string has no well-defined byte encoding, and silently truncating the
/// trailing nibble (the previous behavior of `hex.length ~/ 2`) could
/// misdecode attacker- or corruption-supplied data without any signal.
Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw FormatException(
      'hexDecode: odd-length input (${hex.length} chars) has no '
      'well-defined byte encoding',
      hex,
    );
  }
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
