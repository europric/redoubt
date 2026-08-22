/// crypto-hdkey CBOR codec — CBOR tag 303, per BCR-2020-007
/// (github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-007-hdkey.md).
///
/// Field-key numbers were cross-checked against KeystoneHQ's own
/// `bc-ur-registry` TypeScript source (github.com/KeystoneHQ/ur-registry,
/// `src/CryptoHDKey.ts`), which uses this same "version 1" tag (303) that
/// Keystone hardware wallets and MetaMask Extension actually speak.
///
/// **Scope**: this vault only ever needs an HD key for one purpose — the
/// `m/44'/60'/0'` pairing xpub shown as a QR on the Account screen (never a
/// private key, never any other coin/child-derivation metadata). This type
/// therefore implements `is-master` (1), `is-private` (2), `key-data` (3),
/// `chain-code` (4), `origin` (6) and `parent-fingerprint` (8) — the fields
/// the pairing flow and its sourced test vectors exercise — and
/// intentionally omits `use-info`/`children`/`name`/`note` (5, 7, 9, 10),
/// which this app never sets or reads.
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'crypto_keypath.dart';

/// The CBOR tag for a crypto-hdkey map.
const int cryptoHdKeyCborTag = 303;

const int _keyIsMaster = 1;
const int _keyIsPrivate = 2;
const int _keyKeyData = 3;
const int _keyChainCode = 4;
const int _keyOrigin = 6;
const int _keyParentFingerprint = 8;

/// Thrown when a crypto-hdkey CBOR value fails to decode.
class CryptoHdKeyDecodeException implements Exception {
  final String message;
  CryptoHdKeyDecodeException(this.message);

  @override
  String toString() => 'CryptoHdKeyDecodeException: $message';
}

/// An HD key: either a master key (always private, always has a chain code,
/// no derivation metadata) or a derived key (usually public in this app's
/// use — the pairing xpub — but the private-key bit is preserved on decode
/// for round-trip fidelity).
class CryptoHdKey {
  final bool isMaster;
  final bool isPrivateKey;
  final Uint8List keyData;
  final Uint8List? chainCode;
  final CryptoKeypath? origin;
  final int? parentFingerprint;

  const CryptoHdKey._({
    required this.isMaster,
    required this.isPrivateKey,
    required this.keyData,
    this.chainCode,
    this.origin,
    this.parentFingerprint,
  });

  /// A master key: always private, always has a chain code, no `origin`.
  factory CryptoHdKey.master({
    required List<int> keyData,
    required List<int> chainCode,
  }) {
    return CryptoHdKey._(
      isMaster: true,
      isPrivateKey: true,
      keyData: Uint8List.fromList(keyData),
      chainCode: Uint8List.fromList(chainCode),
    );
  }

  /// A derived key (public by default — this vault never encodes a derived
  /// private key into a QR).
  factory CryptoHdKey.derived({
    required List<int> keyData,
    List<int>? chainCode,
    bool isPrivateKey = false,
    CryptoKeypath? origin,
    int? parentFingerprint,
  }) {
    return CryptoHdKey._(
      isMaster: false,
      isPrivateKey: isPrivateKey,
      keyData: Uint8List.fromList(keyData),
      chainCode: chainCode == null ? null : Uint8List.fromList(chainCode),
      origin: origin,
      parentFingerprint: parentFingerprint,
    );
  }

  /// Builds the nestable, tag-303 [CborValue].
  CborValue toCborValue() {
    final map = <CborValue, CborValue>{};
    if (isMaster) {
      map[const CborSmallInt(_keyIsMaster)] = const CborBool(true);
    } else if (isPrivateKey) {
      map[const CborSmallInt(_keyIsPrivate)] = const CborBool(true);
    }
    map[const CborSmallInt(_keyKeyData)] = CborBytes(keyData);
    if (chainCode != null) {
      map[const CborSmallInt(_keyChainCode)] = CborBytes(chainCode!);
    }
    if (origin != null) {
      map[const CborSmallInt(_keyOrigin)] = origin!.toCborValue();
    }
    if (parentFingerprint != null) {
      map[const CborSmallInt(_keyParentFingerprint)] = CborSmallInt(parentFingerprint!);
    }
    // Note: unlike a NESTED crypto-keypath/crypto-hdkey (which self-tags so
    // a polymorphic parent map can tell field types apart — see
    // `CryptoKeypath.toCborValue`), the OUTERMOST payload of a standalone
    // `ur:crypto-hdkey/...` UR is untagged: the UR's own `type` string
    // ("crypto-hdkey") is what identifies it. Confirmed against
    // KeystoneHQ/ur-registry's `CryptoHDKey.test.ts`, whose
    // `cryptoHDKey.toCBOR()` assertions are untagged hex.
    return CborMap(map);
  }

  /// Encodes this key as standalone (untagged) CBOR bytes — the payload of
  /// a `ur:crypto-hdkey/...` UR.
  Uint8List toCborBytes() => Uint8List.fromList(cbor.encode(toCborValue()));

  /// Decodes standalone (untagged) crypto-hdkey CBOR [data].
  ///
  /// Throws [CryptoHdKeyDecodeException] for malformed input (untrusted
  /// QR/UR boundary) — never lets a decode problem surface as an uncaught
  /// exception type.
  factory CryptoHdKey.fromCborBytes(List<int> data) {
    final CborValue value;
    try {
      value = cbor.decode(data);
    } catch (e) {
      throw CryptoHdKeyDecodeException('invalid CBOR: $e');
    }
    if (value is! CborMap) {
      throw CryptoHdKeyDecodeException('expected a CBOR map, got ${value.runtimeType}');
    }
    final keyDataItem = value[const CborSmallInt(_keyKeyData)];
    if (keyDataItem is! CborBytes) {
      throw CryptoHdKeyDecodeException('missing or invalid key-data field');
    }
    final isMasterItem = value[const CborSmallInt(_keyIsMaster)];
    final isMaster = isMasterItem is CborBool && isMasterItem.value;
    final isPrivateItem = value[const CborSmallInt(_keyIsPrivate)];
    final isPrivateKey = isMaster || (isPrivateItem is CborBool && isPrivateItem.value);
    final chainCodeItem = value[const CborSmallInt(_keyChainCode)];
    final originItem = value[const CborSmallInt(_keyOrigin)];
    final parentFingerprintItem = value[const CborSmallInt(_keyParentFingerprint)];
    return CryptoHdKey._(
      isMaster: isMaster,
      isPrivateKey: isPrivateKey,
      keyData: Uint8List.fromList(keyDataItem.bytes),
      chainCode: chainCodeItem is CborBytes ? Uint8List.fromList(chainCodeItem.bytes) : null,
      origin: originItem != null ? CryptoKeypath.fromCborValue(originItem) : null,
      parentFingerprint:
          parentFingerprintItem is CborSmallInt ? parentFingerprintItem.value : null,
    );
  }
}
