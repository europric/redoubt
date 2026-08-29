/// EIP-712 typed structured data hashing and decoding (GitHub #28,
/// redoubt-critical-fix-round3 design.md D1/D2/D3 — "eip712-personal-sign-
/// support").
///
/// **Decode-as-proof (design.md D1)**: this codebase cannot prove the exact
/// wire-shape of a `typedData` `eth-sign-request`'s `signData` from any
/// primary in-repo evidence (see design.md's investigation table, E1-E7).
/// Rather than assuming a shape, [decodeTypedData] PROVES it per request:
/// `signData` must strictly UTF-8-decode AND `jsonDecode` into a
/// well-formed EIP-712 object carrying `types`/`primaryType`/`domain`/
/// `message`. Success IS the confirmation the assumption held for THIS
/// request; any failure throws [Eip712UnsupportedException] — a false
/// block, identical in shape to the pre-existing (PR1) block screen, never
/// a signature over the wrong bytes.
///
/// **Bounded subset, not universal coverage (design.md D3)**: supports
/// atomics (`address`, `bool`, `string`, `bytes`, `bytes1`..`bytes32`,
/// `uint8`..`uint256`, `int8`..`int256`), custom structs recursively, and
/// one level of arrayness (`T[]`) — nested arrays (`T[][]`) are explicitly
/// unsupported. [eip712MaxDepth]/[eip712MaxNodes]/[eip712MaxArrayLength]
/// bound a malicious/malformed struct's cost; any violation throws
/// [Eip712UnsupportedException] rather than truncating or best-effort
/// rendering. These bounds are checked ONCE, inside [decodeTypedData],
/// before any hashing or UI rendering ever sees the payload (the
/// "rendering-DoS defence": [flattenTypedData] only ever walks an
/// already-bounded structure).
///
/// **No new `blockchain_utils` import site**: reuses [keccak256] from the
/// sibling `signing.dart` via a relative import (precedent: `eip55.dart`),
/// so `tool/lib/architecture_rules.dart`'s R5 gateway allowlist for
/// `blockchain_utils` stays at exactly its current 5 files.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

/// Thrown when a `typedData` payload cannot be decoded, validated, or
/// safely encoded — malformed JSON, missing required top-level fields, an
/// unsupported EIP-712 type construct, or a DoS-bound violation (design.md
/// D1/D3). Every caller treats this uniformly: fail closed, show the
/// named blocked-request screen — never a partial/best-effort render or a
/// signature over unproven bytes.
class Eip712UnsupportedException implements Exception {
  const Eip712UnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'Eip712UnsupportedException: $message';
}

/// Max custom-struct nesting depth (design.md D3's DoS bound). The
/// `primaryType` struct itself is depth 1.
const eip712MaxDepth = 5;

/// Max total encoded/walked field-value nodes across the whole message
/// (design.md D3's DoS bound) — bounds total work regardless of shape.
const eip712MaxNodes = 256;

/// Max element count for any single `T[]` array field (design.md D3's DoS
/// bound).
const eip712MaxArrayLength = 64;

/// A single flattened display row (design.md D3's rendering-DoS defence):
/// [indent] is the nesting depth for visual indentation only — the WIDGET
/// that renders a `List<FlatRow>` must build a flat `Column`/list, never a
/// recursive widget tree, no matter how [indent] varies.
class FlatRow {
  const FlatRow({required this.indent, required this.label, required this.value});

  final int indent;
  final String label;
  final String value;
}

/// D1's decode-as-proof gate. Decodes [signData] as UTF-8 JSON and
/// validates the minimal EIP-712 envelope shape (`types` containing at
/// least `EIP712Domain` and the declared `primaryType`, `domain`,
/// `message`), then walks the (`types`, `primaryType`, `message`) shape
/// once to enforce [eip712MaxDepth]/[eip712MaxNodes]/[eip712MaxArrayLength]
/// — so every caller downstream ([eip712Digest], [flattenTypedData]) can
/// trust the result is already bounded-safe. Throws
/// [Eip712UnsupportedException] on ANY failure.
Map<String, dynamic> decodeTypedData(Uint8List signData) {
  final String jsonText;
  try {
    jsonText = utf8.decode(signData, allowMalformed: false);
  } on FormatException catch (e) {
    throw Eip712UnsupportedException('signData is not valid UTF-8: $e');
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw Eip712UnsupportedException('signData is not valid JSON: $e');
  }

  if (decoded is! Map<String, dynamic>) {
    throw const Eip712UnsupportedException('decoded JSON is not an object');
  }

  final types = decoded['types'];
  final primaryType = decoded['primaryType'];
  final domain = decoded['domain'];
  final message = decoded['message'];

  if (types is! Map ||
      primaryType is! String ||
      domain is! Map ||
      message is! Map) {
    throw const Eip712UnsupportedException(
      'missing or malformed types/primaryType/domain/message',
    );
  }
  if (!types.containsKey('EIP712Domain')) {
    throw const Eip712UnsupportedException(
      'types is missing the EIP712Domain definition',
    );
  }
  if (!types.containsKey(primaryType)) {
    throw Eip712UnsupportedException(
      'types is missing the primaryType ($primaryType) definition',
    );
  }

  final ctx = _BoundsCounter();
  _walkBounded(primaryType, message, types, ctx, 1);

  return decoded;
}

/// `encodeType` per the EIP-712 spec: the primary type's own field-list
/// string, followed by every custom type it (transitively) references,
/// sorted alphabetically, each concatenated with no separator.
String encodeType(String primaryType, Map types) {
  final deps = _customTypeDeps(primaryType, types, <String>{})
    ..remove(primaryType);
  final sortedDeps = deps.toList()..sort();
  final buffer = StringBuffer(_typeString(primaryType, types));
  for (final dep in sortedDeps) {
    buffer.write(_typeString(dep, types));
  }
  return buffer.toString();
}

/// `keccak256(encodeType(type, types))`.
Uint8List _typeHash(String type, Map types) =>
    keccak256(utf8.encode(encodeType(type, types)));

/// `keccak256(encodeData(type, types, data))` — the EIP-712 struct hash.
Uint8List hashStruct(String type, Map types, Map data) =>
    keccak256(_encodeData(type, types, data));

/// `hashStruct('EIP712Domain', types, domain)`.
Uint8List domainSeparator(Map types, Map domain) =>
    hashStruct('EIP712Domain', types, domain);

/// The full EIP-712 signing digest: `keccak256(0x19 0x01 ||
/// domainSeparator || hashStruct(primaryType, message))`. [typedData] is
/// the decoded envelope shape [decodeTypedData] returns (or an equivalent
/// hand-built map for direct/golden-vector testing).
Uint8List eip712Digest(Map<String, dynamic> typedData) {
  final types = typedData['types'] as Map;
  final primaryType = typedData['primaryType'] as String;
  final domain = typedData['domain'] as Map;
  final message = typedData['message'] as Map;

  final ds = domainSeparator(types, domain);
  final hs = hashStruct(primaryType, types, message);

  final builder = BytesBuilder(copy: false);
  builder.add(const [0x19, 0x01]);
  builder.add(ds);
  builder.add(hs);
  return keccak256(builder.toBytes());
}

/// Flattens a decoded [typedData]'s `message` (against `primaryType`) into
/// a flat `List<FlatRow>` for display — never a recursive widget tree
/// (design.md D3). Safe to call on any [typedData] that already passed
/// [decodeTypedData]'s bounds check.
List<FlatRow> flattenTypedData(Map<String, dynamic> typedData) {
  final types = typedData['types'] as Map;
  final primaryType = typedData['primaryType'] as String;
  final message = typedData['message'] as Map;

  final rows = <FlatRow>[];
  _flattenStruct(primaryType, message, types, rows, 0);
  return rows;
}

void _flattenStruct(
  String type,
  Map value,
  Map types,
  List<FlatRow> rows,
  int indent,
) {
  final fields = types[type] as List;
  for (final rawField in fields) {
    final field = rawField as Map;
    final name = field['name'] as String;
    final fieldType = field['type'] as String;
    final fieldValue = value[name];

    if (types.containsKey(fieldType)) {
      rows.add(FlatRow(indent: indent, label: name, value: '{ $fieldType }'));
      _flattenStruct(fieldType, fieldValue as Map, types, rows, indent + 1);
    } else if (fieldType.endsWith('[]')) {
      final base = fieldType.substring(0, fieldType.length - 2);
      final list = fieldValue as List;
      rows.add(
        FlatRow(
          indent: indent,
          label: name,
          value: '[${list.length} item(s)]',
        ),
      );
      for (var i = 0; i < list.length; i++) {
        if (types.containsKey(base)) {
          rows.add(
            FlatRow(indent: indent + 1, label: '$name[$i]', value: '{ $base }'),
          );
          _flattenStruct(base, list[i] as Map, types, rows, indent + 2);
        } else {
          rows.add(
            FlatRow(indent: indent + 1, label: '$name[$i]', value: '${list[i]}'),
          );
        }
      }
    } else {
      rows.add(FlatRow(indent: indent, label: name, value: '$fieldValue'));
    }
  }
}

// ---------------------------------------------------------------------------
// Bounds enforcement (design.md D3) — walked ONCE, inside decodeTypedData.
// ---------------------------------------------------------------------------

class _BoundsCounter {
  int nodes = 0;
}

void _walkBounded(
  String fieldType,
  dynamic value,
  Map types,
  _BoundsCounter ctx,
  int depth,
) {
  ctx.nodes++;
  if (ctx.nodes > eip712MaxNodes) {
    throw const Eip712UnsupportedException(
      'exceeds the max total node count ($eip712MaxNodes)',
    );
  }
  if (depth > eip712MaxDepth) {
    throw const Eip712UnsupportedException(
      'exceeds the max struct nesting depth ($eip712MaxDepth)',
    );
  }

  if (types.containsKey(fieldType)) {
    if (value is! Map) {
      throw Eip712UnsupportedException(
        'expected an object for struct type $fieldType',
      );
    }
    final fields = types[fieldType];
    if (fields is! List) {
      throw Eip712UnsupportedException(
        'types[$fieldType] must be a field-definition list',
      );
    }
    for (final rawField in fields) {
      if (rawField is! Map ||
          rawField['name'] is! String ||
          rawField['type'] is! String) {
        throw const Eip712UnsupportedException('malformed field definition');
      }
      final name = rawField['name'] as String;
      final type = rawField['type'] as String;
      if (!value.containsKey(name)) {
        throw Eip712UnsupportedException(
          'message is missing field "$name" for type $fieldType',
        );
      }
      _walkBounded(type, value[name], types, ctx, depth + 1);
    }
    return;
  }

  if (fieldType.endsWith('[]')) {
    final base = fieldType.substring(0, fieldType.length - 2);
    if (base.endsWith('[]') || base.contains('[')) {
      throw const Eip712UnsupportedException(
        'nested arrays (T[][]) are not supported',
      );
    }
    if (value is! List) {
      throw const Eip712UnsupportedException(
        'expected a list for an array field',
      );
    }
    if (value.length > eip712MaxArrayLength) {
      throw const Eip712UnsupportedException(
        'array exceeds the max length ($eip712MaxArrayLength)',
      );
    }
    if (!types.containsKey(base) && !_isAtomicType(base)) {
      throw Eip712UnsupportedException(
        'unsupported array element type: $base',
      );
    }
    for (final item in value) {
      _walkBounded(base, item, types, ctx, depth);
    }
    return;
  }

  if (!_isAtomicType(fieldType)) {
    throw Eip712UnsupportedException('unsupported type construct: $fieldType');
  }
}

final _uintIntTypeRe = RegExp(
  r'^(uint|int)(8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|'
  r'152|160|168|176|184|192|200|208|216|224|232|240|248|256)$',
);
final _bytesNTypeRe = RegExp(
  r'^bytes([1-9]|1[0-9]|2[0-9]|3[0-2])$',
);

bool _isAtomicType(String t) {
  if (t == 'address' || t == 'bool' || t == 'string' || t == 'bytes') {
    return true;
  }
  return _uintIntTypeRe.hasMatch(t) || _bytesNTypeRe.hasMatch(t);
}

// ---------------------------------------------------------------------------
// Encoding (EIP-712 encodeData) — assumes bounds already proven by
// decodeTypedData; used both for golden-vector direct calls and for the
// real digest computation.
// ---------------------------------------------------------------------------

Set<String> _customTypeDeps(String type, Map types, Set<String> seen) {
  if (!types.containsKey(type) || seen.contains(type)) return seen;
  seen.add(type);
  final fields = types[type] as List;
  for (final rawField in fields) {
    final field = rawField as Map;
    final fieldType = field['type'] as String;
    final base = fieldType.endsWith('[]')
        ? fieldType.substring(0, fieldType.length - 2)
        : fieldType;
    if (types.containsKey(base) && base != type) {
      _customTypeDeps(base, types, seen);
    }
  }
  return seen;
}

String _typeString(String type, Map types) {
  final fields = types[type] as List;
  final fieldStrings = fields.map((rawField) {
    final field = rawField as Map;
    return '${field['type']} ${field['name']}';
  }).join(',');
  return '$type($fieldStrings)';
}

Uint8List _encodeData(String type, Map types, Map data) {
  final builder = BytesBuilder(copy: false);
  builder.add(_typeHash(type, types));
  final fields = types[type] as List;
  for (final rawField in fields) {
    final field = rawField as Map;
    final name = field['name'] as String;
    final fieldType = field['type'] as String;
    builder.add(_encodeValue(fieldType, data[name], types));
  }
  return builder.toBytes();
}

Uint8List _encodeValue(String fieldType, dynamic value, Map types) {
  if (types.containsKey(fieldType)) {
    return hashStruct(fieldType, types, value as Map);
  }
  if (fieldType.endsWith('[]')) {
    final base = fieldType.substring(0, fieldType.length - 2);
    final list = value as List;
    final builder = BytesBuilder(copy: false);
    for (final item in list) {
      builder.add(_encodeValue(base, item, types));
    }
    return keccak256(builder.toBytes());
  }
  if (fieldType == 'string') {
    return keccak256(utf8.encode(value as String));
  }
  if (fieldType == 'bytes') {
    return keccak256(_dynamicBytesToList(value));
  }
  if (fieldType == 'bool') {
    return _leftPad32(Uint8List.fromList([(value as bool) ? 1 : 0]));
  }
  if (fieldType == 'address') {
    return _leftPad32(_hexToBytes(value as String, expectedLength: 20));
  }
  if (_bytesNTypeRe.hasMatch(fieldType)) {
    return _rightPad32(_dynamicBytesToList(value));
  }
  if (_uintIntTypeRe.hasMatch(fieldType)) {
    return _bigIntTo32Bytes(_toBigInt(value));
  }
  throw Eip712UnsupportedException('unsupported type construct: $fieldType');
}

BigInt _toBigInt(dynamic value) {
  if (value is int) return BigInt.from(value);
  if (value is String) {
    if (value.startsWith('0x') || value.startsWith('0X')) {
      return BigInt.parse(value.substring(2), radix: 16);
    }
    return BigInt.parse(value);
  }
  throw Eip712UnsupportedException('unsupported numeric value: $value');
}

List<int> _dynamicBytesToList(dynamic value) {
  if (value is String) return _hexToBytes(value);
  if (value is List<int>) return value;
  throw Eip712UnsupportedException('unsupported bytes value: $value');
}

Uint8List _hexToBytes(String hex, {int? expectedLength}) {
  final clean = hex.startsWith('0x') || hex.startsWith('0X')
      ? hex.substring(2)
      : hex;
  final bytes = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  if (expectedLength != null && bytes.length != expectedLength) {
    throw Eip712UnsupportedException(
      'expected $expectedLength bytes, got ${bytes.length}',
    );
  }
  return bytes;
}

Uint8List _leftPad32(List<int> bytes) {
  final out = Uint8List(32);
  out.setRange(32 - bytes.length, 32, bytes);
  return out;
}

Uint8List _rightPad32(List<int> bytes) {
  final out = Uint8List(32);
  out.setRange(0, bytes.length, bytes);
  return out;
}

Uint8List _bigIntTo32Bytes(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  if (hex.length < 64) hex = hex.padLeft(64, '0');
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
