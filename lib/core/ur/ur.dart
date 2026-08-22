/// Single-part Uniform Resource (UR) codec per BCR-2020-005.
///
/// A single-part UR has the form `ur:<type>/<message>` where `<type>` is
/// restricted to letters, digits and hyphen, and `<message>` is the
/// minimal-Bytewords encoding (see [encodeMinimal]) of the untagged CBOR
/// payload.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'bytewords.dart';
import 'fountain.dart';

/// Thrown when [decodeSinglePart] is given input that is not a valid
/// single-part UR string: missing `ur:` scheme, missing type/message
/// separator, an invalid type, or an underlying Bytewords decode failure
/// (malformed message / checksum mismatch).
class UrDecodeException implements Exception {
  final String message;
  UrDecodeException(this.message);

  @override
  String toString() => 'UrDecodeException: $message';
}

final RegExp _typePattern = RegExp(r'^[A-Za-z0-9-]+$');

/// Encodes [payload] (untagged CBOR bytes) as a single-part
/// `ur:<type>/<message>` string, lowercase.
///
/// [type] must consist only of English letters, Arabic numerals, and `-`
/// per the spec's "Types" section.
String encodeSinglePart(String type, List<int> payload) {
  if (!_typePattern.hasMatch(type)) {
    throw ArgumentError.value(
      type,
      'type',
      'UR type must consist only of letters, digits or hyphen',
    );
  }
  return 'ur:${type.toLowerCase()}/${encodeMinimal(payload)}';
}

/// The result of decoding a single-part UR: its `type` component
/// (lowercased) and decoded `payload` bytes.
class DecodedUr {
  final String type;
  final Uint8List payload;
  DecodedUr(this.type, this.payload);
}

/// Decodes a single-part UR [text]. Accepts any letter case (UR strings
/// are case-agnostic per the spec) and normalizes [DecodedUr.type] to
/// lowercase.
///
/// Throws [UrDecodeException] for malformed input, including a multi-part
/// UR (`ur:<type>/<seq>/<fragment>`) — this decoder only handles the
/// single-part form; multi-part reassembly is `fountain.dart`'s job.
DecodedUr decodeSinglePart(String text) {
  final lower = text.toLowerCase();
  if (!lower.startsWith('ur:')) {
    throw UrDecodeException('missing "ur:" scheme');
  }
  final rest = lower.substring(3);
  final firstSlash = rest.indexOf('/');
  if (firstSlash == -1) {
    throw UrDecodeException('missing type/message separator');
  }
  final type = rest.substring(0, firstSlash);
  final message = rest.substring(firstSlash + 1);
  if (!_typePattern.hasMatch(type)) {
    throw UrDecodeException('invalid UR type "$type"');
  }
  if (message.contains('/')) {
    throw UrDecodeException(
      'input is a multi-part UR (contains "seq"); use the fountain decoder',
    );
  }
  final Uint8List payload;
  try {
    payload = decodeMinimal(message);
  } on BytewordsDecodeException catch (e) {
    throw UrDecodeException('invalid Bytewords message: ${e.message}');
  }
  return DecodedUr(type, payload);
}

/// Uppercases a canonical (lowercase) UR string for QR rendering — the
/// spec requires uppercase so the QR encoder can use alphanumeric mode
/// (~1.55x denser than byte mode). Decode-side always lowercases first
/// (see [decodeSinglePart]), so this is safe to call unconditionally.
String toQrUppercase(String ur) => ur.toUpperCase();

/// The result of decoding one animated multi-part BC-UR frame: its `type`
/// component (lowercased) and the reconstructed [FountainPart] ready to
/// feed into a [FountainDecoder].
class DecodedMultiPartUr {
  final String type;
  final FountainPart part;
  DecodedMultiPartUr(this.type, this.part);
}

/// Encodes one [part] as an animated multi-part BC-UR frame:
/// `ur:<type>/<seqNum>-<seqLen>/<message>`, where `<message>` is the
/// minimal-Bytewords encoding of the CBOR 5-element array `[seqNum, seqLen,
/// messageLength, checksum, fragment]`, per BCR-2020-005's "Sequencing"
/// section. Pair with [decodeMultiPart] to parse a scanned frame back into
/// a [FountainPart].
///
/// **Compatibility note**: this CBOR envelope framing is hand-ported from
/// the published BCR-2020-005 spec text (no local reference
/// implementation was available to diff against — see design.md's "THE
/// CENTRAL DESIGN DECISION" section) and is exercised only by this
/// codebase's own self-consistent round-trip tests, not against a real
/// captured multi-part scan from MetaMask Extension or a hardware wallet.
/// (Unlike this framing, `fountain.dart`'s fragment-*selection* algorithm
/// — which decides which fragments a mixed part combines — is now a
/// verified bit-for-bit port of the reference BC-UR algorithm; see
/// `lib/core/ur/xoshiro256.dart`'s doc comment.)
String encodeMultiPart(String type, FountainPart part) {
  if (!_typePattern.hasMatch(type)) {
    throw ArgumentError.value(
      type,
      'type',
      'UR type must consist only of letters, digits or hyphen',
    );
  }
  final partPayload = cbor.encode(
    CborValue([
      part.seqNum,
      part.seqLen,
      part.messageLength,
      part.checksum,
      part.fragment,
    ]),
  );
  return 'ur:${type.toLowerCase()}/${part.seqNum}-${part.seqLen}/${encodeMinimal(partPayload)}';
}

/// Decodes one scanned multi-part BC-UR frame [text] (any letter case).
///
/// Throws [UrDecodeException] for malformed input: missing `ur:` scheme,
/// missing type/sequence or sequence/message separators, an invalid type,
/// a non-`<seqNum>-<seqLen>` sequence indicator, a Bytewords/checksum
/// failure, or a fragment envelope that isn't the expected 5-element CBOR
/// array — this is an untrusted, attacker-controllable QR boundary, so it
/// never lets a decode problem surface as an uncaught exception type.
DecodedMultiPartUr decodeMultiPart(String text) {
  final lower = text.toLowerCase();
  if (!lower.startsWith('ur:')) {
    throw UrDecodeException('missing "ur:" scheme');
  }
  final rest = lower.substring(3);
  final firstSlash = rest.indexOf('/');
  if (firstSlash == -1) {
    throw UrDecodeException('missing type/sequence separator');
  }
  final type = rest.substring(0, firstSlash);
  if (!_typePattern.hasMatch(type)) {
    throw UrDecodeException('invalid UR type "$type"');
  }
  final afterType = rest.substring(firstSlash + 1);
  final secondSlash = afterType.indexOf('/');
  if (secondSlash == -1) {
    throw UrDecodeException(
      'not a multi-part UR (missing sequence/message separator); use decodeSinglePart',
    );
  }
  final seqIndicator = afterType.substring(0, secondSlash);
  final message = afterType.substring(secondSlash + 1);
  final dash = seqIndicator.indexOf('-');
  if (dash == -1) {
    throw UrDecodeException(
      'invalid sequence indicator "$seqIndicator", expected "<seqNum>-<seqLen>"',
    );
  }
  final seqNum = int.tryParse(seqIndicator.substring(0, dash));
  final seqLen = int.tryParse(seqIndicator.substring(dash + 1));
  if (seqNum == null || seqLen == null || seqNum < 1 || seqLen < 1) {
    throw UrDecodeException('invalid sequence indicator "$seqIndicator"');
  }
  final Uint8List partPayload;
  try {
    partPayload = decodeMinimal(message);
  } on BytewordsDecodeException catch (e) {
    throw UrDecodeException('invalid Bytewords message: ${e.message}');
  }
  final CborValue decoded;
  try {
    decoded = cbor.decode(partPayload);
  } catch (e) {
    throw UrDecodeException('invalid multi-part CBOR envelope: $e');
  }
  if (decoded is! CborList || decoded.length != 5) {
    throw UrDecodeException(
      'expected a 5-element CBOR array for a multi-part fragment envelope',
    );
  }
  final seqNumItem = decoded[0];
  final seqLenItem = decoded[1];
  final messageLengthItem = decoded[2];
  final checksumItem = decoded[3];
  final fragmentItem = decoded[4];
  if (seqNumItem is! CborInt ||
      seqLenItem is! CborInt ||
      messageLengthItem is! CborInt ||
      checksumItem is! CborInt ||
      fragmentItem is! CborBytes) {
    throw UrDecodeException('malformed multi-part fragment envelope');
  }
  if (seqNumItem.toInt() != seqNum || seqLenItem.toInt() != seqLen) {
    throw UrDecodeException(
      'sequence indicator disagrees with the embedded fragment envelope',
    );
  }
  return DecodedMultiPartUr(
    type,
    FountainPart(
      seqNum: seqNumItem.toInt(),
      seqLen: seqLenItem.toInt(),
      messageLength: messageLengthItem.toInt(),
      checksum: checksumItem.toInt(),
      fragment: Uint8List.fromList(fragmentItem.bytes),
    ),
  );
}
