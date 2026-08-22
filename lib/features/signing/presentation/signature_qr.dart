/// Builds the `eth-signature` (CBOR tag 402) BC-UR QR payload(s) for the
/// Signature screen (`qr-air-gapped-signing` spec's "Offline Sign And
/// BC-UR Signature Output" requirement).
///
/// **Structural guarantee**: [buildSignatureQrFrames] accepts only a
/// [SignedResult] — a value object that carries a completed signature and
/// echoed request-id, never a private key or seed material (see
/// `SignedResult`'s own doc comment) — so, matching `pairing_qr.dart`'s
/// same guarantee for the pairing QR, it is structurally impossible to hand
/// this function anything that could re-expose vault secrets.
library;

import 'package:redoubt/core/ur/ur_api.dart';

import '../domain/signed_result.dart';

/// The maximum single-part payload length (bytes) before this falls back to
/// an animated multi-part sequence. `eth-signature` payloads are small
/// (a 65-byte signature plus a 16-byte UUID and a short origin string), so
/// in practice this almost always renders as one QR — the multi-part path
/// exists for completeness (`qr-air-gapped-signing` spec explicitly
/// requires "animated/multi-part if required by payload size").
const int defaultMaxSignatureFragmentLength = 150;

/// Builds one or more uppercased BC-UR frames encoding [result] as
/// `ur:eth-signature/...`. Returns exactly one frame (a single-part UR) if
/// the CBOR-encoded payload fits within [maxFragmentLength] bytes;
/// otherwise returns an animated multi-part sequence (one frame per
/// fountain part, `fountain.dart`'s pure encoder — no mixed/redundant
/// parts needed since the sender fully controls delivery order here,
/// unlike the untrusted scan-side decoder).
///
/// `ur.dart`'s [toQrUppercase] gotcha applies to every frame: uppercase so
/// the QR encoder can use alphanumeric mode.
List<String> buildSignatureQrFrames(
  SignedResult result, {
  int maxFragmentLength = defaultMaxSignatureFragmentLength,
}) {
  final signature = EthSignature(
    signature: result.signature,
    requestId: result.requestId,
    origin: result.origin,
  );
  final payload = signature.toCborBytes();

  if (payload.length <= maxFragmentLength) {
    return [toQrUppercase(encodeSinglePart('eth-signature', payload))];
  }

  final parts = encode(payload, maxFragmentLength: maxFragmentLength);
  return [
    for (final part in parts)
      toQrUppercase(encodeMultiPart('eth-signature', part)),
  ];
}
