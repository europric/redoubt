/// EIP-55 mixed-case checksum encoding for Ethereum addresses (#21,
/// `eip55-address-display` spec).
///
/// **Single shared implementation**: every human-facing address display
/// surface in this app renders through [eip55ChecksumAddress] (or already
/// does, via `blockchain_utils`'s `EthAddrEncoder.encodeKey` — see this
/// function's doc comment on byte-identical output). Mirrors
/// `EthAddrUtils._checksumEncode` (`package:blockchain_utils`) exactly:
/// keccak256 over the lowercase-hex ASCII string, then a nibble >= 8 in
/// the resulting digest uppercases the corresponding address character.
///
/// **No new `blockchain_utils` import site**: this file imports
/// [keccak256] from the sibling `signing.dart` (a relative import,
/// per `core/eth`'s "files inside import siblings relatively" convention
/// — see `eth.dart`'s own doc comment) instead of importing
/// `package:blockchain_utils` directly, so
/// `tool/lib/architecture_rules.dart`'s R5 gateway allowlist for
/// `blockchain_utils` stays at exactly its current 5 files.
library;

import 'dart:convert';

import 'signing.dart';

/// Returns [address] rendered in EIP-55 checksum case.
///
/// Accepts [address] with or without a `0x` prefix, in any input casing —
/// output casing is derived purely from the keccak256 digest of the
/// lowercased hex, never from the caller's input casing. The returned
/// string is always `0x`-prefixed, matching
/// `EthAddrEncoder().encodeKey(...)`'s existing output format.
///
/// Throws [FormatException] unless the address (after stripping an
/// optional `0x` prefix) is exactly 40 hexadecimal characters.
String eip55ChecksumAddress(String address) {
  final withoutPrefix = address.startsWith('0x') || address.startsWith('0X')
      ? address.substring(2)
      : address;

  if (withoutPrefix.length != 40) {
    throw FormatException(
      'eip55ChecksumAddress: expected exactly 40 hex characters '
      '(got ${withoutPrefix.length})',
      address,
    );
  }
  if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(withoutPrefix)) {
    throw FormatException(
      'eip55ChecksumAddress: input is not valid hexadecimal',
      address,
    );
  }

  final lower = withoutPrefix.toLowerCase();
  final digestHex = _bytesToHex(keccak256(utf8.encode(lower)));

  final buffer = StringBuffer('0x');
  for (var i = 0; i < lower.length; i++) {
    final nibble = int.parse(digestHex[i], radix: 16);
    buffer.write(nibble >= 8 ? lower[i].toUpperCase() : lower[i]);
  }
  return buffer.toString();
}

String _bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
