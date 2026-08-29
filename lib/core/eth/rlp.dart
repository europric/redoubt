/// Recursive Length Prefix (RLP) codec, as specified by the Ethereum
/// Yellow Paper's Appendix B and used by EIP-155 legacy transaction signing.
///
/// This is a generic byte-string/list codec — the same encoder handles both
/// EIP-155 legacy transactions (a 9-element list) and, at the item level,
/// the payload of an EIP-1559 typed transaction (`0x02 || rlp([...])`,
/// where only the outer `0x02` type byte and the field list differ). No
/// EIP-1559 fixture was available to source real test vectors for the typed
/// envelope (see design.md's "no fabricated vectors" rule, matched here),
/// so only the EIP-155 legacy shape is exercised by tests in this PR; the
/// codec itself makes no legacy-only assumptions.
library;

import 'dart:typed_data';

/// Thrown when [rlpDecode] is given malformed input: a length prefix that
/// overruns the buffer, a non-canonical (non-minimal) length encoding, or
/// trailing bytes after a complete top-level item.
class RlpDecodeException implements Exception {
  final String message;
  RlpDecodeException(this.message);

  @override
  String toString() => 'RlpDecodeException: $message';
}

/// One RLP-encodable item: either a byte string ([RlpBytes]) or a list of
/// items ([RlpList]).
sealed class RlpItem {
  const RlpItem();
}

/// An RLP byte string.
class RlpBytes extends RlpItem {
  final Uint8List data;
  RlpBytes(List<int> data) : data = Uint8List.fromList(data);
}

/// An RLP list of items.
class RlpList extends RlpItem {
  final List<RlpItem> items;
  const RlpList(this.items);
}

/// Encodes an unsigned integer [value] as an [RlpBytes] using RLP's minimal
/// big-endian representation (no leading zero bytes; zero itself is the
/// empty byte string).
RlpItem rlpUint(int value) => rlpBigInt(BigInt.from(value));

/// Encodes an unsigned [BigInt] [value] as an [RlpBytes] using RLP's minimal
/// big-endian representation.
RlpItem rlpBigInt(BigInt value) {
  if (value.isNegative) {
    throw ArgumentError.value(value, 'value', 'RLP integers must be non-negative');
  }
  if (value == BigInt.zero) {
    return RlpBytes(const []);
  }
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return RlpBytes(bytes);
}

/// Encodes [item] per the RLP spec.
Uint8List rlpEncode(RlpItem item) {
  return switch (item) {
    RlpBytes(:final data) => _encodeBytes(data),
    RlpList(:final items) => _encodeList(items.map(rlpEncode).toList()),
  };
}

Uint8List _encodeBytes(Uint8List data) {
  if (data.length == 1 && data[0] < 0x80) {
    return data;
  }
  return _withLengthPrefix(0x80, data);
}

Uint8List _encodeList(List<Uint8List> encodedItems) {
  final payload = BytesBuilder();
  for (final e in encodedItems) {
    payload.add(e);
  }
  return _withLengthPrefix(0xc0, payload.toBytes());
}

/// Shared "short/long" length-prefix framing used by both byte-string
/// (`baseOffset` 0x80) and list (`baseOffset` 0xc0) encoding.
Uint8List _withLengthPrefix(int baseOffset, Uint8List payload) {
  final out = BytesBuilder();
  if (payload.length <= 55) {
    out.addByte(baseOffset + payload.length);
  } else {
    var lengthHex = payload.length.toRadixString(16);
    if (lengthHex.length.isOdd) lengthHex = '0$lengthHex';
    final lengthBytes = Uint8List(lengthHex.length ~/ 2);
    for (var i = 0; i < lengthBytes.length; i++) {
      lengthBytes[i] = int.parse(lengthHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    out.addByte(baseOffset + 55 + lengthBytes.length);
    out.add(lengthBytes);
  }
  out.add(payload);
  return out.toBytes();
}

/// Decodes a single, complete top-level RLP [item] from [data].
///
/// Throws [RlpDecodeException] if [data] is empty, a length prefix overruns
/// the buffer, or bytes remain after the first complete item — this
/// boundary handles untrusted/attacker-controlled transaction bytes, so it
/// never lets a decode problem surface as an uncaught exception type.
RlpItem rlpDecode(Uint8List data) {
  if (data.isEmpty) {
    throw RlpDecodeException('empty input');
  }
  final result = _decodeOne(data, 0);
  if (result.nextOffset != data.length) {
    throw RlpDecodeException(
      'trailing bytes after top-level item (consumed ${result.nextOffset} of ${data.length})',
    );
  }
  return result.item;
}

class _DecodeResult {
  final RlpItem item;
  final int nextOffset;
  _DecodeResult(this.item, this.nextOffset);
}

_DecodeResult _decodeOne(Uint8List data, int offset) {
  if (offset >= data.length) {
    throw RlpDecodeException('unexpected end of input at offset $offset');
  }
  final prefix = data[offset];
  if (prefix < 0x80) {
    return _DecodeResult(RlpBytes([prefix]), offset + 1);
  }
  if (prefix <= 0xb7) {
    final length = prefix - 0x80;
    final start = offset + 1;
    _checkBounds(data, start, length);
    return _DecodeResult(
      RlpBytes(data.sublist(start, start + length)),
      start + length,
    );
  }
  if (prefix <= 0xbf) {
    final (:start, :length) = _decodeLongFormLength(data, offset, 0xb7);
    return _DecodeResult(
      RlpBytes(data.sublist(start, start + length)),
      start + length,
    );
  }
  if (prefix <= 0xf7) {
    final length = prefix - 0xc0;
    final start = offset + 1;
    _checkBounds(data, start, length);
    return _DecodeResult(
      RlpList(_decodeItems(data, start, start + length)),
      start + length,
    );
  }
  final (:start, :length) = _decodeLongFormLength(data, offset, 0xf7);
  return _DecodeResult(
    RlpList(_decodeItems(data, start, start + length)),
    start + length,
  );
}

List<RlpItem> _decodeItems(Uint8List data, int start, int end) {
  final items = <RlpItem>[];
  var offset = start;
  while (offset < end) {
    final result = _decodeOne(data, offset);
    if (result.nextOffset > end) {
      throw RlpDecodeException('nested item overruns its enclosing list length');
    }
    items.add(result.item);
    offset = result.nextOffset;
  }
  return items;
}

/// Decodes a long-form length prefix (`lengthOfLength` byte(s) followed by
/// the encoded length itself) shared by the byte-string (`longFormBase`
/// `0xb7`) and list (`longFormBase` `0xf7`) branches of [_decodeOne].
///
/// Rejects any `lengthOfLength > 7` with [RlpDecodeException] BEFORE
/// computing bounds or the length value itself — `lengthOfLength` bytes
/// shifted through [_bytesToLength] can overflow a 64-bit int (producing a
/// negative or wrapped value) for 8+ bytes, which would otherwise surface
/// as an unhandled [RangeError] deeper in [_checkBounds]/`sublist`.
({int start, int length}) _decodeLongFormLength(
  Uint8List data,
  int offset,
  int longFormBase,
) {
  final lengthOfLength = data[offset] - longFormBase;
  if (lengthOfLength > 7) {
    throw RlpDecodeException(
      'length-of-length too large ($lengthOfLength bytes, max 7)',
    );
  }
  final lengthStart = offset + 1;
  _checkBounds(data, lengthStart, lengthOfLength);
  final length = _bytesToLength(data.sublist(lengthStart, lengthStart + lengthOfLength));
  final start = lengthStart + lengthOfLength;
  _checkBounds(data, start, length);
  return (start: start, length: length);
}

void _checkBounds(Uint8List data, int start, int length) {
  if (start + length > data.length) {
    throw RlpDecodeException('length prefix overruns buffer');
  }
}

int _bytesToLength(List<int> bytes) {
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | b;
  }
  return value;
}
