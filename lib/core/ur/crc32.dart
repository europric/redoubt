/// CRC-32 (ISO-HDLC / zlib variant: polynomial `0xEDB88320` reflected,
/// init `0xFFFFFFFF`, xorout `0xFFFFFFFF`), as required by BCR-2020-012
/// (Bytewords "Checksum" section) and BCR-2020-005 (Uniform Resources).
library;

import 'dart:typed_data';

/// Computes the CRC-32 checksum of [data].
int crc32(List<int> data) {
  final table = _table;
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Computes the CRC-32 checksum of [data] and returns it as 4 big-endian
/// bytes ("network order"), matching how Bytewords appends it.
Uint8List crc32Bytes(List<int> data) {
  final value = crc32(data);
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xFF
    ..[1] = (value >> 16) & 0xFF
    ..[2] = (value >> 8) & 0xFF
    ..[3] = value & 0xFF;
}

final List<int> _table = _buildTable();

List<int> _buildTable() {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    table[n] = c;
  }
  return table;
}
