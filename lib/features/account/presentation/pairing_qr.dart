/// Builds the `crypto-hdkey` (CBOR tag 303) BC-UR pairing QR payload for
/// the Account screen (`qr-air-gapped-signing` spec's "Pairing QR Precedes
/// Signing" requirement).
///
/// **Structural guarantee**: [buildPairingQrUrString] accepts only an
/// [AccountPairingKey] — a public-key-only value object (see its own doc
/// comment). There is no seed/mnemonic/private-key-shaped parameter on
/// this function's signature, so it is structurally impossible to hand it
/// anything that could re-expose the vault's seed, matching design.md's
/// explicit requirement for whatever builds this QR.
library;

import 'package:redoubt/core/ur/ur_api.dart';

import '../domain/account_derivation_service.dart';

/// Encodes [key] as an uppercased, single-part `ur:crypto-hdkey/...`
/// string ready for QR rendering (`ur.dart`'s [toQrUppercase] gotcha:
/// uppercase so the QR encoder can use alphanumeric mode).
String buildPairingQrUrString(AccountPairingKey key) {
  final origin = CryptoKeypath(
    components: [
      for (final index in key.pathIndexes)
        PathComponent(index: index, hardened: true),
    ],
    sourceFingerprint: key.sourceFingerprint,
    depth: key.depth,
  );
  final hdKey = CryptoHdKey.derived(
    keyData: key.publicKeyCompressed,
    chainCode: key.chainCode,
    origin: origin,
    parentFingerprint: key.parentFingerprint,
  );
  return toQrUppercase(encodeSinglePart('crypto-hdkey', hdKey.toCborBytes()));
}
