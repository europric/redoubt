/// The signing feature's own domain view of a scanned, fully reassembled
/// BC-UR `eth-sign-request` — a thin abstraction over
/// `core/ur/registry/eth_sign_request.dart`'s CBOR codec type so
/// `TransactionSigner`/`QrFrameSource` consumers never need to know about
/// CBOR/UR framing (design.md's "Layering" decision: every new feature gets
/// domain/data/presentation because it owns a native-plugin or crypto
/// boundary that must be fakeable).
library;

import 'dart:typed_data';

import 'package:redoubt/core/eth/eth.dart';
import 'package:redoubt/core/ur/ur_api.dart';

/// A signing request, plus a best-effort decoded transaction summary for
/// the review screen (`qr-air-gapped-signing` spec's "Offline Sign And
/// BC-UR Signature Output" requirement implies the user must be able to
/// review what they're signing before authenticating).
class SignRequest {
  final Uint8List? requestId;
  final Uint8List signData;
  final EthSignDataType dataType;
  final int? chainId;
  final String? origin;

  /// The RLP-decoded `to` address, as `0x`-prefixed hex, when [dataType] is
  /// [EthSignDataType.transaction] and [signData] parses as a 6+ element
  /// RLP list (`nonce, gasPrice, gasLimit, to, value, data, ...`, matching
  /// the field order KeystoneHQ's own `EthSignRequest.test.ts` fixture
  /// uses — see `test/support/fixtures/bc_ur_registry_eth_fixtures.dart`).
  /// `null` for any other data type or an unparsable payload — this is a
  /// best-effort display aid, never a signing precondition.
  final String? toAddressHex;

  /// The RLP-decoded `value` field, in wei, under the same conditions as
  /// [toAddressHex].
  final BigInt? valueWei;

  /// The RLP-decoded `data` field, as `0x`-prefixed hex, under the same
  /// conditions as [toAddressHex].
  final String? dataHex;

  const SignRequest({
    this.requestId,
    required this.signData,
    required this.dataType,
    this.chainId,
    this.origin,
    this.toAddressHex,
    this.valueWei,
    this.dataHex,
  });

  /// Builds a [SignRequest] from a decoded [EthSignRequest], attempting the
  /// RLP summary decode for [EthSignDataType.transaction] (legacy EIP-155
  /// RLP, `[nonce, gasPrice, gasLimit, to, value, data, ...]`) and
  /// [EthSignDataType.typedTransaction] (a leading tx-type byte followed by
  /// an RLP list — EIP-2930 `0x01` or EIP-1559 `0x02`, which is what
  /// MetaMask Extension's QR hardware-wallet flow actually sends for its
  /// default gas model) payloads only. A malformed/unparsable `signData`,
  /// or a typed-transaction type byte this vault doesn't recognize, never
  /// throws here — [toAddressHex], [valueWei] and [dataHex] simply stay
  /// `null`; the review screen falls back to showing only the fields that
  /// did decode.
  factory SignRequest.fromEthSignRequest(EthSignRequest request) {
    String? toAddressHex;
    BigInt? valueWei;
    String? dataHex;

    try {
      final _TxFieldLayout? layout = switch (request.dataType) {
        EthSignDataType.transaction => const _TxFieldLayout(
          rlpBytes: null, // legacy: the whole signData is the RLP list
          toIndex: 3,
          valueIndex: 4,
          dataIndex: 5,
        ),
        EthSignDataType.typedTransaction => _typedTransactionLayout(
          request.signData,
        ),
        _ => null,
      };
      if (layout != null) {
        final decoded = rlpDecode(layout.rlpBytes ?? request.signData);
        final minLength = layout.dataIndex + 1;
        if (decoded is RlpList && decoded.items.length >= minLength) {
          final to = decoded.items[layout.toIndex];
          final value = decoded.items[layout.valueIndex];
          final data = decoded.items[layout.dataIndex];
          if (to is RlpBytes) toAddressHex = '0x${_toHex(to.data)}';
          if (value is RlpBytes) valueWei = _bytesToBigInt(value.data);
          if (data is RlpBytes) dataHex = '0x${_toHex(data.data)}';
        }
      }
    } on RlpDecodeException {
      // Best-effort only — leave the summary fields null.
    }

    return SignRequest(
      requestId: request.requestId,
      signData: request.signData,
      dataType: request.dataType,
      chainId: request.chainId,
      origin: request.origin,
      toAddressHex: toAddressHex,
      valueWei: valueWei,
      dataHex: dataHex,
    );
  }
}

/// Where `to`/`value`/`data` sit inside a transaction's RLP field list, and
/// which bytes to RLP-decode to find that list.
class _TxFieldLayout {
  /// The bytes to feed to [rlpDecode] — `null` means "use `signData`
  /// as-is" (the legacy/[EthSignDataType.transaction] case, which has no
  /// leading type byte to strip).
  final Uint8List? rlpBytes;
  final int toIndex;
  final int valueIndex;
  final int dataIndex;

  const _TxFieldLayout({
    required this.rlpBytes,
    required this.toIndex,
    required this.valueIndex,
    required this.dataIndex,
  });
}

/// Resolves the field layout for an [EthSignDataType.typedTransaction]
/// payload: a leading tx-type byte (per EIP-2718's "TransactionType")
/// followed by an RLP-encoded field list whose shape depends on that type.
/// Returns `null` for an empty payload or a type byte this vault doesn't
/// recognize — the caller then leaves the summary fields null rather than
/// guessing at a layout.
_TxFieldLayout? _typedTransactionLayout(Uint8List signData) {
  if (signData.isEmpty) return null;
  final typeByte = signData[0];
  final rlpBytes = Uint8List.sublistView(signData, 1);
  return switch (typeByte) {
    // EIP-2930: [chainId, nonce, gasPrice, gasLimit, to, value, data, accessList]
    0x01 => _TxFieldLayout(
      rlpBytes: rlpBytes,
      toIndex: 4,
      valueIndex: 5,
      dataIndex: 6,
    ),
    // EIP-1559: [chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList]
    0x02 => _TxFieldLayout(
      rlpBytes: rlpBytes,
      toIndex: 5,
      valueIndex: 6,
      dataIndex: 7,
    ),
    _ => null,
  };
}

String _toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final b in bytes) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  return value;
}
