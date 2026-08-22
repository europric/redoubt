/// crypto-keypath CBOR codec — CBOR tag 304, per BCR-2020-007
/// (github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-007-hdkey.md).
///
/// Field layout and the flat (non-nested) `[index, hardened, index,
/// hardened, ...]` components encoding were cross-checked against
/// KeystoneHQ's own `bc-ur-registry` TypeScript source
/// (github.com/KeystoneHQ/ur-registry, `src/CryptoKeypath.ts`), which uses
/// this same tag number (304 — the "version 1" `crypto-keypath` tag that
/// Keystone hardware wallets and MetaMask Extension actually speak; BCR's
/// November-2023 "version 2" revision moved to tag 40304 for new
/// deployments but documents that the map field layout is unchanged).
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

/// The CBOR tag for a crypto-keypath map.
const int cryptoKeypathCborTag = 304;

const int _keyComponents = 1;
const int _keySourceFingerprint = 2;
const int _keyDepth = 3;

/// Thrown when a crypto-keypath CBOR value fails to decode.
class CryptoKeypathDecodeException implements Exception {
  final String message;
  CryptoKeypathDecodeException(this.message);

  @override
  String toString() => 'CryptoKeypathDecodeException: $message';
}

/// One derivation step: a child index (or a wildcard, `index == null`) plus
/// whether it is hardened.
class PathComponent {
  final int? index;
  final bool hardened;

  const PathComponent({this.index, required this.hardened});

  bool get isWildcard => index == null;
}

/// A (possibly partial) BIP-32 derivation path plus optional
/// source-fingerprint/depth metadata, per BCR-2020-007.
class CryptoKeypath {
  final List<PathComponent> components;
  final int? sourceFingerprint;
  final int? depth;

  const CryptoKeypath({
    this.components = const [],
    this.sourceFingerprint,
    this.depth,
  });

  /// Builds the nestable, tag-304 [CborValue] for embedding inside another
  /// registry map (e.g. `crypto-hdkey`'s `origin` field).
  CborValue toCborValue() {
    final componentItems = <CborValue>[];
    for (final component in components) {
      componentItems.add(
        component.isWildcard ? CborList(const []) : CborSmallInt(component.index!),
      );
      componentItems.add(CborBool(component.hardened));
    }
    final map = <CborValue, CborValue>{
      const CborSmallInt(_keyComponents): CborList(componentItems),
      if (sourceFingerprint != null)
        const CborSmallInt(_keySourceFingerprint): CborSmallInt(sourceFingerprint!),
      if (depth != null) const CborSmallInt(_keyDepth): CborSmallInt(depth!),
    };
    return CborMap(map, tags: [cryptoKeypathCborTag]);
  }

  /// Encodes this keypath as standalone tag-304 CBOR bytes.
  Uint8List toCborBytes() => Uint8List.fromList(cbor.encode(toCborValue()));

  /// Parses a nested tag-304 [value] (e.g. extracted from a `crypto-hdkey`
  /// map's `origin` field) back into a [CryptoKeypath].
  factory CryptoKeypath.fromCborValue(CborValue value) {
    if (value is! CborMap) {
      throw CryptoKeypathDecodeException(
        'expected a CBOR map, got ${value.runtimeType}',
      );
    }
    if (!value.tags.contains(cryptoKeypathCborTag)) {
      throw CryptoKeypathDecodeException(
        'missing CBOR tag $cryptoKeypathCborTag, got tags ${value.tags}',
      );
    }
    final componentsValue = value[const CborSmallInt(_keyComponents)];
    final components = <PathComponent>[];
    if (componentsValue is CborList) {
      if (componentsValue.length.isOdd) {
        throw CryptoKeypathDecodeException(
          'components array must have an even length (index/hardened pairs)',
        );
      }
      for (var i = 0; i < componentsValue.length; i += 2) {
        final indexItem = componentsValue[i];
        final hardenedItem = componentsValue[i + 1];
        if (hardenedItem is! CborBool) {
          throw CryptoKeypathDecodeException('expected a bool at hardened position');
        }
        if (indexItem is CborList) {
          components.add(PathComponent(hardened: hardenedItem.value));
        } else if (indexItem is CborSmallInt) {
          components.add(
            PathComponent(index: indexItem.value, hardened: hardenedItem.value),
          );
        } else {
          throw CryptoKeypathDecodeException(
            'expected an int or empty array at index position, got ${indexItem.runtimeType}',
          );
        }
      }
    }
    final sourceFingerprintItem = value[const CborSmallInt(_keySourceFingerprint)];
    final depthItem = value[const CborSmallInt(_keyDepth)];
    return CryptoKeypath(
      components: components,
      sourceFingerprint:
          sourceFingerprintItem is CborSmallInt ? sourceFingerprintItem.value : null,
      depth: depthItem is CborSmallInt ? depthItem.value : null,
    );
  }

  /// Decodes standalone tag-304 CBOR [data].
  ///
  /// Throws [CryptoKeypathDecodeException] for malformed input (untrusted
  /// QR/UR boundary) — never lets a decode problem surface as an uncaught
  /// exception type.
  factory CryptoKeypath.fromCborBytes(List<int> data) {
    final CborValue value;
    try {
      value = cbor.decode(data);
    } catch (e) {
      throw CryptoKeypathDecodeException('invalid CBOR: $e');
    }
    return CryptoKeypath.fromCborValue(value);
  }
}
