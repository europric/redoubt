/// The signing feature's domain view of a completed signature — what
/// [TransactionSigner.sign] returns and what the signature QR screen
/// renders (`qr-air-gapped-signing` spec's "Offline Sign And BC-UR
/// Signature Output" requirement).
library;

import 'dart:typed_data';

/// A completed ECDSA signature (`r || s || v`, 65 bytes) plus the
/// request-id it answers (if the original request carried one, per
/// `core/ur/registry/eth_sign_request.dart`'s optional `requestId` field).
class SignedResult {
  final Uint8List signature;
  final Uint8List? requestId;
  final String? origin;

  const SignedResult({required this.signature, this.requestId, this.origin});
}
