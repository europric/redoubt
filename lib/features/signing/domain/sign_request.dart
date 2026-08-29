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
  ///
  /// GitHub #18: [fromEthSignRequest] decodes this field, [valueWei] and
  /// [dataHex] as a single all-or-nothing outcome — either all three are
  /// non-null or all three are null, never a mix. See [hasDecodedSummary].
  /// A hand-built [SignRequest] via the public `const` constructor below is
  /// NOT covered by that guarantee (design.md D3) — [hasDecodedSummary]
  /// reports the true per-instance state regardless of how it was built.
  ///
  /// GitHub #48: the atomic outcome now also covers [nonceValue],
  /// [gasLimit], and the active transaction type's gas price field(s) — see
  /// those fields' docs and [hasDecodedSummary].
  final String? toAddressHex;

  /// The RLP-decoded `value` field, in wei, under the same conditions as
  /// [toAddressHex].
  final BigInt? valueWei;

  /// The RLP-decoded `data` field, as `0x`-prefixed hex, under the same
  /// conditions as [toAddressHex].
  final String? dataHex;

  /// The RLP-decoded `nonce` field, under the same all-or-nothing
  /// conditions as [toAddressHex]. Set for every recognized transaction
  /// type (GitHub #48).
  final BigInt? nonceValue;

  /// The RLP-decoded `gasLimit` field — a dimensionless gas-unit count,
  /// never wei-denominated (hence no `Wei` suffix, unlike the price fields
  /// below) — under the same all-or-nothing conditions as [toAddressHex].
  /// Set for every recognized transaction type (GitHub #48).
  final BigInt? gasLimit;

  /// The RLP-decoded `gasPrice` field, in wei per gas unit, under the same
  /// all-or-nothing conditions as [toAddressHex]. Set for legacy and
  /// EIP-2930 transactions; always `null` for EIP-1559, which uses
  /// [maxFeePerGasWei]/[maxPriorityFeePerGasWei] instead (GitHub #48).
  final BigInt? gasPriceWei;

  /// The RLP-decoded `maxFeePerGas` field (EIP-1559), in wei per gas unit,
  /// under the same all-or-nothing conditions as [toAddressHex]. `null` for
  /// legacy/EIP-2930 transactions, which use [gasPriceWei] instead
  /// (GitHub #48).
  final BigInt? maxFeePerGasWei;

  /// The RLP-decoded `maxPriorityFeePerGas` field (EIP-1559), in wei per
  /// gas unit, under the same all-or-nothing conditions as [toAddressHex].
  /// `null` for legacy/EIP-2930 transactions (GitHub #48).
  final BigInt? maxPriorityFeePerGasWei;

  const SignRequest({
    this.requestId,
    required this.signData,
    required this.dataType,
    this.chainId,
    this.origin,
    this.toAddressHex,
    this.valueWei,
    this.dataHex,
    this.nonceValue,
    this.gasLimit,
    this.gasPriceWei,
    this.maxFeePerGasWei,
    this.maxPriorityFeePerGasWei,
  });

  /// True iff [toAddressHex], [valueWei], [dataHex], [nonceValue] and
  /// [gasLimit] ALL decoded, AND exactly one complete gas-price model is
  /// present — either [gasPriceWei] alone (legacy/EIP-2930), or both
  /// [maxFeePerGasWei] and [maxPriorityFeePerGasWei] (EIP-1559). The review
  /// screen renders the structured card layout (including the gas/network
  /// fee card, GitHub #48) ONLY when this holds; a partial decode is
  /// deliberately downgraded to the undecodable fallback (GitHub #18)
  /// rather than shown as a complete-looking summary with an "Unknown" card
  /// standing in for the field that failed. Derived, never stored, so it
  /// can never drift from the fields it reports on.
  bool get hasDecodedSummary =>
      toAddressHex != null &&
      valueWei != null &&
      dataHex != null &&
      nonceValue != null &&
      gasLimit != null &&
      (gasPriceWei != null ||
          (maxFeePerGasWei != null && maxPriorityFeePerGasWei != null));

  /// Builds a [SignRequest] from a decoded [EthSignRequest], attempting the
  /// RLP summary decode for [EthSignDataType.transaction] (legacy EIP-155
  /// RLP, `[nonce, gasPrice, gasLimit, to, value, data, ...]`) and
  /// [EthSignDataType.typedTransaction] (a leading tx-type byte followed by
  /// an RLP list — EIP-2930 `0x01` or EIP-1559 `0x02`, which is what
  /// MetaMask Extension's QR hardware-wallet flow actually sends for its
  /// default gas model) payloads only. A malformed/unparsable `signData`,
  /// or a typed-transaction type byte this vault doesn't recognize, never
  /// throws here — [toAddressHex], [valueWei], [dataHex] and the gas fields
  /// simply stay `null`; the review screen falls back to showing only the
  /// fields that did decode.
  ///
  /// GitHub #18 (widened by #48): `to`/`value`/`data`/`nonce`/`gasLimit`
  /// and the active type's gas price field(s) are decoded as a single
  /// atomic outcome — either every declared RLP item is a well-formed
  /// [RlpBytes] and every summary field is set, or none are. A single
  /// corrupted field (e.g. a nested [RlpList] where [RlpBytes] was
  /// expected) must never leave the other fields set, which would let the
  /// review screen render a complete-looking summary around tampered data.
  factory SignRequest.fromEthSignRequest(EthSignRequest request) {
    String? toAddressHex;
    BigInt? valueWei;
    String? dataHex;
    BigInt? nonceValue;
    BigInt? gasLimit;
    BigInt? gasPriceWei;
    BigInt? maxFeePerGasWei;
    BigInt? maxPriorityFeePerGasWei;

    try {
      final _TxFieldLayout? layout = switch (request.dataType) {
        EthSignDataType.transaction => const _TxFieldLayout(
          rlpBytes: null, // legacy: the whole signData is the RLP list
          nonceIndex: 0,
          gasPriceIndex: 1,
          gasLimitIndex: 2,
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
          final nonce = decoded.items[layout.nonceIndex];
          final gasLimitItem = decoded.items[layout.gasLimitIndex];
          final gasPriceIdx = layout.gasPriceIndex;
          final maxFeeIdx = layout.maxFeePerGasIndex;
          final maxPriorityIdx = layout.maxPriorityFeePerGasIndex;
          final gasPriceItem = gasPriceIdx == null
              ? null
              : decoded.items[gasPriceIdx];
          final maxFeeItem = maxFeeIdx == null
              ? null
              : decoded.items[maxFeeIdx];
          final maxPriorityItem = maxPriorityIdx == null
              ? null
              : decoded.items[maxPriorityIdx];
          // GitHub #18/#48: one combined guard, not eight independent
          // ones — either every declared field decodes, or none of them
          // do. `null` here means "the layout does not declare this
          // index", never "decode failed" — see _TxFieldLayout.
          if (to is RlpBytes &&
              value is RlpBytes &&
              data is RlpBytes &&
              nonce is RlpBytes &&
              gasLimitItem is RlpBytes &&
              (gasPriceItem == null || gasPriceItem is RlpBytes) &&
              (maxFeeItem == null || maxFeeItem is RlpBytes) &&
              (maxPriorityItem == null || maxPriorityItem is RlpBytes)) {
            toAddressHex = '0x${_toHex(to.data)}';
            valueWei = _bytesToBigInt(value.data);
            dataHex = '0x${_toHex(data.data)}';
            nonceValue = _bytesToBigInt(nonce.data);
            gasLimit = _bytesToBigInt(gasLimitItem.data);
            gasPriceWei = gasPriceItem is RlpBytes
                ? _bytesToBigInt(gasPriceItem.data)
                : null;
            maxFeePerGasWei = maxFeeItem is RlpBytes
                ? _bytesToBigInt(maxFeeItem.data)
                : null;
            maxPriorityFeePerGasWei = maxPriorityItem is RlpBytes
                ? _bytesToBigInt(maxPriorityItem.data)
                : null;
          }
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
      nonceValue: nonceValue,
      gasLimit: gasLimit,
      gasPriceWei: gasPriceWei,
      maxFeePerGasWei: maxFeePerGasWei,
      maxPriorityFeePerGasWei: maxPriorityFeePerGasWei,
    );
  }
}

/// Where `to`/`value`/`data`/`nonce`/`gasLimit`/gas-price field(s) sit
/// inside a transaction's RLP field list, and which bytes to RLP-decode to
/// find that list. [nonceIndex]/[gasLimitIndex] are non-nullable — every
/// recognized transaction type declares both. The gas price indices are
/// nullable and mutually exclusive by design: legacy/EIP-2930 declare only
/// [gasPriceIndex]; EIP-1559 declares only [maxFeePerGasIndex] and
/// [maxPriorityFeePerGasIndex] (GitHub #48).
class _TxFieldLayout {
  /// The bytes to feed to [rlpDecode] — `null` means "use `signData`
  /// as-is" (the legacy/[EthSignDataType.transaction] case, which has no
  /// leading type byte to strip).
  final Uint8List? rlpBytes;
  final int nonceIndex;
  final int toIndex;
  final int valueIndex;
  final int dataIndex;
  final int gasLimitIndex;
  final int? gasPriceIndex;
  final int? maxFeePerGasIndex;
  final int? maxPriorityFeePerGasIndex;

  const _TxFieldLayout({
    required this.rlpBytes,
    required this.nonceIndex,
    required this.toIndex,
    required this.valueIndex,
    required this.dataIndex,
    required this.gasLimitIndex,
    this.gasPriceIndex,
    this.maxFeePerGasIndex,
    this.maxPriorityFeePerGasIndex,
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
      nonceIndex: 1,
      gasPriceIndex: 2,
      gasLimitIndex: 3,
      toIndex: 4,
      valueIndex: 5,
      dataIndex: 6,
    ),
    // EIP-1559: [chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList]
    0x02 => _TxFieldLayout(
      rlpBytes: rlpBytes,
      nonceIndex: 1,
      maxPriorityFeePerGasIndex: 2,
      maxFeePerGasIndex: 3,
      gasLimitIndex: 4,
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
