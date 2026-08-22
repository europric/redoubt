/// eth-signature CBOR codec — CBOR tag 402, defined by Keystone (not a core
/// Blockchain Commons BCR type).
///
/// Field-key numbers and the "outer payload is untagged" shape were
/// cross-checked against KeystoneHQ's own `bc-ur-registry-eth` TypeScript
/// source (real GitHub source, not just its npm README):
/// github.com/KeystoneHQ/keystone-sdk-base,
/// `packages/ur-registry-eth/src/EthSignature.ts`.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'uuid.dart';

/// The CBOR tag registered for eth-signature (used as the `ur:` type string
/// "eth-signature", not applied to the outer CBOR payload).
const int ethSignatureCborTag = 402;

const int _keyRequestId = 1;
const int _keySignature = 2;
const int _keyOrigin = 3;

/// Thrown when an eth-signature CBOR value fails to decode.
class EthSignatureDecodeException implements Exception {
  final String message;
  EthSignatureDecodeException(this.message);

  @override
  String toString() => 'EthSignatureDecodeException: $message';
}

/// A completed signature (`r || s || v`, 65 bytes) to render as a QR for
/// MetaMask Extension to scan, optionally echoing back the request-id it
/// answers.
class EthSignature {
  final Uint8List? requestId;
  final Uint8List signature;
  final String? origin;

  const EthSignature({required this.signature, this.requestId, this.origin});

  CborValue toCborValue() {
    // Inserted in strict ascending key order (1..3) — see
    // `eth_sign_request.dart`'s note on canonical field ordering.
    final map = <CborValue, CborValue>{};
    if (requestId != null) {
      map[const CborSmallInt(_keyRequestId)] = uuidToCborValue(requestId!);
    }
    map[const CborSmallInt(_keySignature)] = CborBytes(signature);
    if (origin != null) {
      map[const CborSmallInt(_keyOrigin)] = CborString(origin!);
    }
    return CborMap(map);
  }

  Uint8List toCborBytes() => Uint8List.fromList(cbor.encode(toCborValue()));

  /// Decodes standalone (untagged) eth-signature CBOR [data].
  ///
  /// Throws [EthSignatureDecodeException] for malformed input (untrusted
  /// QR/UR boundary) — never lets a decode problem surface as an uncaught
  /// exception type.
  factory EthSignature.fromCborBytes(List<int> data) {
    final CborValue value;
    try {
      value = cbor.decode(data);
    } catch (e) {
      throw EthSignatureDecodeException('invalid CBOR: $e');
    }
    if (value is! CborMap) {
      throw EthSignatureDecodeException('expected a CBOR map, got ${value.runtimeType}');
    }
    final signatureItem = value[const CborSmallInt(_keySignature)];
    if (signatureItem is! CborBytes) {
      throw EthSignatureDecodeException('missing or invalid signature field');
    }
    final requestIdItem = value[const CborSmallInt(_keyRequestId)];
    final originItem = value[const CborSmallInt(_keyOrigin)];
    return EthSignature(
      signature: Uint8List.fromList(signatureItem.bytes),
      requestId: requestIdItem != null ? uuidFromCborValue(requestIdItem) : null,
      origin: originItem is CborString ? originItem.toString() : null,
    );
  }
}
