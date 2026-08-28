/// eth-sign-request CBOR codec — CBOR tag 401, defined by Keystone (not a
/// core Blockchain Commons BCR type).
///
/// Field-key numbers, the `DataType` enum values, and the "outer payload is
/// untagged" shape were cross-checked against KeystoneHQ's own
/// `bc-ur-registry-eth` TypeScript source (real GitHub source, not just its
/// npm README — the README has no hex fixtures, as PR1 already found):
/// github.com/KeystoneHQ/keystone-sdk-base,
/// `packages/ur-registry-eth/src/EthSignRequest.ts`.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'crypto_keypath.dart';
import 'uuid.dart';

/// The CBOR tag registered for eth-sign-request (used as the `ur:` type
/// string "eth-sign-request", not applied to the outer CBOR payload — see
/// `crypto_hdkey.dart`'s note on standalone-vs-nested tagging).
const int ethSignRequestCborTag = 401;

const int _keyRequestId = 1;
const int _keySignData = 2;
const int _keyDataType = 3;
const int _keyChainId = 4;
const int _keyDerivationPath = 5;
const int _keyAddress = 6;
const int _keyOrigin = 7;

/// What kind of payload `signData` carries — matches Keystone's `DataType`
/// enum exactly (`transaction = 1` is the only value this vault currently
/// produces/consumes; the others are recognized for forward compatibility
/// with whatever MetaMask Extension may send).
enum EthSignDataType {
  transaction(1),
  typedData(2),
  personalMessage(3),
  typedTransaction(4);

  const EthSignDataType(this.value);
  final int value;

  static EthSignDataType fromValue(int value) {
    for (final candidate in values) {
      if (candidate.value == value) return candidate;
    }
    throw EthSignRequestDecodeException('unknown data-type value $value');
  }
}

/// Thrown when an eth-sign-request CBOR value fails to decode.
class EthSignRequestDecodeException implements Exception {
  final String message;
  EthSignRequestDecodeException(this.message);

  @override
  String toString() => 'EthSignRequestDecodeException: $message';
}

/// A signing request scanned from MetaMask Extension: the payload to sign,
/// what kind of payload it is, and the derivation path to sign it with.
class EthSignRequest {
  final Uint8List? requestId;
  final Uint8List signData;
  final EthSignDataType dataType;
  final int? chainId;
  final CryptoKeypath derivationPath;
  final Uint8List? address;
  final String? origin;

  const EthSignRequest({
    this.requestId,
    required this.signData,
    required this.dataType,
    this.chainId,
    required this.derivationPath,
    this.address,
    this.origin,
  });

  /// Builds the standalone (untagged) CBOR payload — see
  /// `crypto_hdkey.dart`'s note: the outer item of a `ur:type/...` payload
  /// is untagged; only nested fields (here, `derivationPath` and
  /// `requestId`) self-tag.
  CborValue toCborValue() {
    // Inserted in strict ascending key order (1..7) so canonical CBOR
    // serialization matches the reference implementation byte-for-byte,
    // regardless of which optional fields are present — Dart's `Map`
    // preserves insertion order, it does not sort automatically.
    final map = <CborValue, CborValue>{};
    if (requestId != null) {
      map[const CborSmallInt(_keyRequestId)] = uuidToCborValue(requestId!);
    }
    map[const CborSmallInt(_keySignData)] = CborBytes(signData);
    map[const CborSmallInt(_keyDataType)] = CborSmallInt(dataType.value);
    if (chainId != null) {
      map[const CborSmallInt(_keyChainId)] = CborSmallInt(chainId!);
    }
    map[const CborSmallInt(_keyDerivationPath)] = derivationPath.toCborValue();
    if (address != null) {
      map[const CborSmallInt(_keyAddress)] = CborBytes(address!);
    }
    if (origin != null) {
      map[const CborSmallInt(_keyOrigin)] = CborString(origin!);
    }
    return CborMap(map);
  }

  Uint8List toCborBytes() => Uint8List.fromList(cbor.encode(toCborValue()));

  /// Decodes standalone (untagged) eth-sign-request CBOR [data].
  ///
  /// Throws [EthSignRequestDecodeException] for malformed input (untrusted
  /// QR/UR boundary) — never lets a decode problem surface as an uncaught
  /// exception type.
  factory EthSignRequest.fromCborBytes(List<int> data) {
    final CborValue value;
    try {
      value = cbor.decode(data);
    } catch (e) {
      throw EthSignRequestDecodeException('invalid CBOR: $e');
    }
    if (value is! CborMap) {
      throw EthSignRequestDecodeException(
        'expected a CBOR map, got ${value.runtimeType}',
      );
    }
    final signDataItem = value[const CborSmallInt(_keySignData)];
    if (signDataItem is! CborBytes) {
      throw EthSignRequestDecodeException('missing or invalid sign-data field');
    }
    final dataTypeItem = value[const CborSmallInt(_keyDataType)];
    if (dataTypeItem is! CborSmallInt) {
      throw EthSignRequestDecodeException('missing or invalid data-type field');
    }
    final derivationPathItem = value[const CborSmallInt(_keyDerivationPath)];
    if (derivationPathItem == null) {
      throw EthSignRequestDecodeException('missing derivation-path field');
    }
    final requestIdItem = value[const CborSmallInt(_keyRequestId)];
    final chainIdItem = value[const CborSmallInt(_keyChainId)];
    final addressItem = value[const CborSmallInt(_keyAddress)];
    final originItem = value[const CborSmallInt(_keyOrigin)];
    final chainId = chainIdItem is CborSmallInt ? chainIdItem.value : null;
    // #31 — a present-but-non-positive chainId must never reach EIP-155 `v`
    // computation (`eip155V` in `core/eth/signing.dart`, applied from
    // `EthTransactionSigner.sign()`): `chainId <= 0` produces a nonsensical/
    // ambiguous `v`. Rejected at the earliest possible chokepoint — decode
    // time — rather than deferred to the signing call site. A request with
    // no chainId at all (`null`, e.g. `personalMessage`) is unaffected.
    if (chainId != null && chainId <= 0) {
      throw EthSignRequestDecodeException('invalid chainId: $chainId (must be > 0)');
    }
    return EthSignRequest(
      requestId: requestIdItem != null ? uuidFromCborValue(requestIdItem) : null,
      signData: Uint8List.fromList(signDataItem.bytes),
      dataType: EthSignDataType.fromValue(dataTypeItem.value),
      chainId: chainId,
      derivationPath: CryptoKeypath.fromCborValue(derivationPathItem),
      address: addressItem is CborBytes ? Uint8List.fromList(addressItem.bytes) : null,
      origin: originItem is CborString ? originItem.toString() : null,
    );
  }
}
