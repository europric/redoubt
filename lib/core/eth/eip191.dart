/// EIP-191 "personal_sign" message digest (GitHub #28, redoubt-critical-
/// fix-round3 design.md D1 — "eip712-personal-sign-support").
///
/// **Decode-as-proof (design.md D1)**: this codebase cannot prove the
/// exact wire-shape of a `personalMessage` `eth-sign-request`'s
/// `signData` from any primary in-repo evidence. Rather than assuming
/// `signData` is raw text, [decodePersonalMessage] PROVES it per request:
/// `signData` must be strictly-valid UTF-8 (32 opaque digest bytes are
/// effectively never valid UTF-8). Success IS the confirmation; any
/// failure throws [FormatException] — a false block, never a signature
/// over the wrong bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'signing.dart';

/// D1's decode-as-proof gate for `personalMessage`: decodes [signData] as
/// strict UTF-8 (`allowMalformed: false`). Throws [FormatException] on
/// invalid UTF-8 — the caller must treat that as a fail-closed block, not
/// a partial/lossy decode.
String decodePersonalMessage(Uint8List signData) =>
    utf8.decode(signData, allowMalformed: false);

/// The EIP-191 "personal_sign" digest:
/// `keccak256("\x19Ethereum Signed Message:\n" + byteLength + signData)`.
/// `byteLength` is [signData]'s BYTE length (not a decoded string's rune/
/// codepoint count) — a multi-byte UTF-8 message must use its UTF-8 byte
/// length to match what `ecrecover`/real wallets expect.
///
/// Calls [decodePersonalMessage] first as the D1 proof step: this throws
/// [FormatException] (fail closed) before any digest is computed if
/// [signData] is not valid UTF-8.
Uint8List eip191Digest(Uint8List signData) {
  decodePersonalMessage(signData); // proof step only — return value unused.
  final prefix = utf8.encode(
    '\x19Ethereum Signed Message:\n${signData.length}',
  );
  final builder = BytesBuilder(copy: false);
  builder.add(prefix);
  builder.add(signData);
  return keccak256(builder.toBytes());
}
