import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/ur/registry/eth_sign_request.dart';
import 'package:redoubt/features/seed/seed.dart';

import 'sign_review_controller.dart';

/// The Sign Review screen (route `/account/sign`).
///
/// `qr-air-gapped-signing` spec's "Offline Sign And BC-UR Signature Output"
/// requirement: shows the decoded transaction summary (to/value/data/
/// chainId — whatever `SignRequest`'s best-effort RLP decode exposes) and
/// requires the user to explicitly confirm before signing.
///
/// **PIN step (vault-secure-storage-redesign PR7)**: tapping "Confirm and
/// Sign" no longer calls [SignReviewController.confirmAndSign] directly —
/// that now requires a PIN, collected on a separate `PinEntryPage` step
/// (`vault-unlock` spec's mandatory-PIN requirement). [onConfirm] is
/// invoked instead, with the [ControllerHost]-owned controller instance;
/// the router wires it to navigate to that step (route `/account/sign/pin`),
/// forwarding that SAME instance via `extra:` so it owns calling
/// [SignReviewController.confirmAndSign] and routing onward once a
/// `SignedResult` exists. This page still surfaces
/// [SignReviewController.state]'s error (e.g. re-shown after returning from
/// a denied/cancelled hardware-auth attempt).
///
/// Wrapped in [SecureScreen] per design.md's "SecureScreen wraps the
/// phrase, review and signature pages" — this screen displays the
/// transaction the vault is about to authorize.
///
/// `state-management-rollout` (Unit 3): this page is now a
/// `StatelessWidget` wrapped in `ControllerHost<SignReviewController>`,
/// which CREATES and owns the controller from [createController] (invoked
/// exactly once) instead of taking an already-constructed `controller`
/// instance — mirrors `ScanPage`'s `state-management-foundation` Pilot A
/// shape. [onConfirm] is a `ValueChanged<SignReviewController>` so the
/// caller always receives the SAME hosted instance to forward through
/// `signPin`'s `extra:` — a builder-local variable would be a different,
/// never-hosted instance (design.md's "onConfirm becomes
/// `ValueChanged<SignReviewController>`" decision).
///
/// **Passphrase opt-in (seed-passphrase-25th-word design.md D4/D6)**: hosts
/// the shared [PassphraseOptInField] (`requireConfirmation: false` — no
/// confirm field at signing; the signing-time address-match guard in
/// `EthTransactionSigner.sign` is a strictly stronger verifier than
/// retyping). Unchecked by default, disclosure-neutral
/// (`critical-screen-ux` spec's "Disclosure-Neutral Passphrase Toggle"
/// requirement) — deliberately NOT hosted on `PinEntryPage`, which is
/// shared across unlock/sign/reveal-seed/delete-account and stays
/// structurally untouched (design.md D4, prior decision D7). A valid
/// opted-in value is written straight onto [controller] via
/// `SignReviewController.setPassphrase` — the SAME instance forwarded to
/// `/account/sign/pin`'s `PinEntryPage.onSubmit`, which calls
/// `confirmAndSign(pin)` and reads it back from there.
///
/// **sign-review-redesign (card-based layout)**: the build method now
/// renders cards grouped by section (Recipient / Amount / Data / Network)
/// with a type-aware layout. [EthSignDataType.transaction] shows all 4
/// cards; [EthSignDataType.typedData] and
/// [EthSignDataType.personalMessage] show a badge + collapsed hex only.
class SignReviewPage extends StatelessWidget {
  const SignReviewPage({
    super.key,
    required this.createController,
    required this.onConfirm,
  });

  /// Invoked exactly once (by [ControllerHost]) to construct this page's
  /// [SignReviewController].
  final SignReviewController Function() createController;

  /// Navigates to the PIN entry step, passing the hosted controller
  /// instance. Does NOT sign directly.
  final ValueChanged<SignReviewController> onConfirm;

  @override
  Widget build(BuildContext context) {
    return ControllerHost<SignReviewController>(
      create: createController,
      builder: (context, controller) {
        final request = controller.request;
        final errorMessage = controller.state.errorOrNull;
        final isLoading = controller.state.isLoading;
        final hasDecodedFields = request.toAddressHex != null ||
            request.valueWei != null ||
            request.dataHex != null;

        return SecureScreen(
          child: Scaffold(
            appBar: AppBar(title: const Text('Review Transaction')),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Data type badge — always shown
                    _DataHeaderBadge(dataType: request.dataType),
                    const SizedBox(height: 16),

                    // Type-aware layout
                    if ((request.dataType == EthSignDataType.transaction ||
                        request.dataType == EthSignDataType.typedTransaction) &&
                        hasDecodedFields) ...[
                      _AddressCard(address: request.toAddressHex),
                      const SizedBox(height: 12),
                      _ValueCard(wei: request.valueWei),
                      const SizedBox(height: 12),
                      _DataCard(dataHex: request.dataHex),
                      const SizedBox(height: 12),
                      _ChainCard(chainId: request.chainId),
                    ] else ...[
                      // typedData / personalMessage — collapsed hex only
                      if (request.dataHex != null)
                        _DataCard(dataHex: request.dataHex),
                      if (request.dataHex == null)
                        const _TransactionReviewCard(
                          label: 'Data',
                          content: Text('No data available'),
                        ),
                    ],

                    const SizedBox(height: 24),
                    if (errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          errorMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    FilledButton(
                      key: const Key('confirmSignButton'),
                      onPressed:
                          isLoading ? null : () => onConfirm(controller),
                      child: isLoading
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Confirm and Sign'),
                    ),
                    PassphraseOptInField(
                      requireConfirmation: false,
                      onChanged: controller.setPassphrase,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 1: Parameter Type Enum (public for testing)
// ═══════════════════════════════════════════════════════════════

/// The encoded parameter types we can display.
// ignore: unused_import — used by tests via package:redoubt
enum ParamType { address, uint256, bytes32 }

// ═══════════════════════════════════════════════════════════════
// Phase 1: Function Signature Data Class (public for testing)
// ═══════════════════════════════════════════════════════════════

/// A decoded function selector entry: the human-readable signature string
/// and the ordered parameter types for basic display.
class FuncSig {
  final String signature;
  final List<ParamType> paramTypes;

  const FuncSig(this.signature, this.paramTypes);
}

// ═══════════════════════════════════════════════════════════════
// Phase 1.3: Chain Names — static const map
// ═══════════════════════════════════════════════════════════════

/// Offline map of known EVM chain IDs to human-readable names.
const _chainNamesMap = <int, String>{
  1: 'Ethereum Mainnet',
  11155111: 'Sepolia',
  10: 'Optimism',
  137: 'Polygon',
  56: 'BNB Smart Chain',
  42161: 'Arbitrum One',
  8453: 'Base',
  43114: 'Avalanche C-Chain',
};

/// Resolves a chain name from the static map. Returns a fallback string
/// with "unknown" for unmapped IDs.
@visibleForTesting
String chainName(int? chainId) {
  if (chainId == null) return 'Unknown';
  return _chainNamesMap[chainId] ?? 'Chain ID: $chainId (unknown)';
}

// ═══════════════════════════════════════════════════════════════
// Phase 1.4: 4-Byte Selector Map (~60 selectors)
// ═══════════════════════════════════════════════════════════════

/// Offline map of common 4-byte function selectors to their human-readable
/// signatures and parameter types. Covers ERC20/721/1155, common DeFi
/// operations (swap, deposit, withdraw, add/remove liquidity), and
/// well-known protocols.
@visibleForTesting
const selectorMap = <int, FuncSig>{
  // ── ERC20 Basics ──
  0xa9059cbb: FuncSig('transfer(address,uint256)', [
    ParamType.address,
    ParamType.uint256,
  ]),
  0x095ea7b3: FuncSig('approve(address,uint256)', [
    ParamType.address,
    ParamType.uint256,
  ]),
  0x23b872dd: FuncSig('transferFrom(address,address,uint256)', [
    ParamType.address,
    ParamType.address,
    ParamType.uint256,
  ]),
  0xdd62ed3e: FuncSig('allowance(address,address)', [
    ParamType.address,
    ParamType.address,
  ]),
  0x70a08231: FuncSig('balanceOf(address)', [
    ParamType.address,
  ]),
  0x18160ddd: FuncSig('totalSupply()', []),
  0x06fdde03: FuncSig('name()', []),
  0x95d89b41: FuncSig('symbol()', []),
  0x313ce567: FuncSig('decimals()', []),

  // ── ERC721 / ERC1155 ──
  0x42842e0e: FuncSig('safeTransferFrom(address,address,uint256)', [
    ParamType.address,
    ParamType.address,
    ParamType.uint256,
  ]),
  0xb88d4fde: FuncSig('safeTransferFrom(address,address,uint256,bytes)', [
    ParamType.address,
    ParamType.address,
    ParamType.uint256,
    ParamType.bytes32,
  ]),
  0xf242432a: FuncSig(
    'safeTransferFrom(address,address,uint256,uint256,bytes)',
    [
      ParamType.address,
      ParamType.address,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
    ],
  ),
  0xa22cb465: FuncSig('setApprovalForAll(address,bool)', [
    ParamType.address,
    ParamType.bytes32,
  ]),
  0x6352211e: FuncSig('ownerOf(uint256)', [
    ParamType.uint256,
  ]),

  // ── DeFi: Uniswap V2 ──
  0x38ed1739: FuncSig(
    'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x7ff36ab5: FuncSig(
    'swapExactETHForTokens(uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x4a25d94a: FuncSig(
    'swapExactTokensForETH(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x18cbafe5: FuncSig(
    'swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x8803dbee: FuncSig(
    'swapTokensForExactTokens(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x5c11d795: FuncSig(
    'swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0x791ac947: FuncSig(
    'swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
    [
      ParamType.uint256,
      ParamType.uint256,
      ParamType.bytes32,
      ParamType.address,
      ParamType.uint256,
    ],
  ),

  // ── DeFi: Uniswap V3 ──
  0xc04b8d59: FuncSig(
    'exactInput((bytes,address,uint256,uint256,uint256))',
    [ParamType.bytes32],
  ),
  0x09b81346: FuncSig(
    'exactOutput((bytes,address,uint256,uint256,uint256))',
    [ParamType.bytes32],
  ),
  0x414bf389: FuncSig(
    'exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint256))',
    [ParamType.bytes32],
  ),
  0xdb3e2198: FuncSig(
    'exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint256))',
    [ParamType.bytes32],
  ),
  0x9e394fac: FuncSig(
    'multicall(bytes[])',
    [ParamType.bytes32],
  ),

  // ── DeFi: WETH / Wrap ──
  0xd0e30db0: FuncSig('deposit()', []),
  0x2e1a7d4d: FuncSig('withdraw(uint256)', [
    ParamType.uint256,
  ]),
  0x3ccfd60b: FuncSig('withdraw(uint256)', [
    ParamType.uint256,
  ]),

  // ── Lending / Staking ──
  0xa0712d68: FuncSig('mint(uint256)', [ParamType.uint256]),
  0x40c10f19: FuncSig('mint(address,uint256)', [
    ParamType.address,
    ParamType.uint256,
  ]),
  0x42966c68: FuncSig('burn(uint256)', [ParamType.uint256]),
  0x9dc29fac: FuncSig('burn(address,uint256)', [
    ParamType.address,
    ParamType.uint256,
  ]),
  0xdb006df8: FuncSig('redeem(uint256)', [ParamType.uint256]),
  0xba087652: FuncSig(
    'redeem(uint256,address,address)',
    [ParamType.uint256, ParamType.address, ParamType.address],
  ),
  0xc6e6f592: FuncSig('borrow(uint256)', [ParamType.uint256]),
  0x0c63a205: FuncSig('stake(uint256)', [ParamType.uint256]),
  0x2e17de78: FuncSig('unstake(uint256)', [ParamType.uint256]),
  0xa694fc3a: FuncSig('claimRewards()', []),

  // ── LP / Liquidity ──
  0xe8e33700: FuncSig(
    'addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)',
    [
      ParamType.address,
      ParamType.address,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.address,
      ParamType.uint256,
    ],
  ),
  0xbaa2abde: FuncSig(
    'removeLiquidity(address,address,uint256,uint256,uint256,address,uint256)',
    [
      ParamType.address,
      ParamType.address,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.uint256,
      ParamType.address,
      ParamType.uint256,
    ],
  ),

  // ── Governance ──
  0x153abe5a: FuncSig(
    'propose(address[],uint256[],bytes[],string)',
    [
      ParamType.bytes32,
      ParamType.bytes32,
      ParamType.bytes32,
      ParamType.bytes32,
    ],
  ),
  0x0121b93f: FuncSig('queue(uint256)', [ParamType.uint256]),
  0xda95691a: FuncSig('execute(uint256)', [ParamType.uint256]),
  0x013cf08b: FuncSig('castVote(uint256,bool)', [
    ParamType.uint256,
    ParamType.bytes32,
  ]),
  0x7b9f48e5: FuncSig('delegate(address)', [ParamType.address]),
  0x1703a5e4: FuncSig('getVotes(address,uint256)', [
    ParamType.address,
    ParamType.uint256,
  ]),

  // ── Common Utilities ──
  0xb61d27f6: FuncSig('execute(address,uint256,bytes)', [
    ParamType.address,
    ParamType.uint256,
    ParamType.bytes32,
  ]),
  0x248566a8: FuncSig('multicall(bytes[])', [ParamType.bytes32]),
  0x8da5cb5b: FuncSig('owner()', []),
  0xf2fde38b: FuncSig('renounceOwnership()', []),
  0x715018a6: FuncSig('transferOwnership(address)', [ParamType.address]),
  0x1626ba7e: FuncSig('isValidSignature(bytes32,bytes)', [
    ParamType.bytes32,
    ParamType.bytes32,
  ]),
};

// ═══════════════════════════════════════════════════════════════
// Phase 1.1: Address Formatting
// ═══════════════════════════════════════════════════════════════

/// Abbreviates a `0x`-prefixed hex address for display.
/// A full 42-char address becomes `0xABCD…EF12`. Shorter hex strings
/// (≤ 12 chars) pass through unmodified.
@visibleForTesting
String abbreviateAddress(String? hex) {
  if (hex == null) return 'Unknown';
  if (hex.length <= 12) return hex;
  return '${hex.substring(0, 6)}…${hex.substring(hex.length - 4)}';
}

// ═══════════════════════════════════════════════════════════════
// Phase 1.2: ETH Value Formatting
// ═══════════════════════════════════════════════════════════════

/// Formats a wei value as a human-readable ETH string.
/// - `null` → `'Unknown'`
/// - `0` → `'0 ETH'`
/// - `< 0.000001 ETH` (≤ 10^12 wei) → `'< 0.000001 ETH'`
/// - Otherwise → `'{amount} ETH'` with up to 6 decimal places.
@visibleForTesting
String formatEth(BigInt? wei) {
  if (wei == null) return 'Unknown';
  if (wei == BigInt.zero) return '0 ETH';

  final oneEth = BigInt.from(1000000000000000000);
  final dustThreshold = BigInt.from(10).pow(12);
  if (wei < dustThreshold) return '< 0.000001 ETH';

  final integerPart = wei ~/ oneEth;
  final fractionalPart = wei % oneEth;

  // Left-pad the fraction to 18 digits
  final fracStr = fractionalPart.toString().padLeft(18, '0');

  if (integerPart > BigInt.zero) {
    // Show up to 6 decimal places, trim trailing zeros
    final trimmed = fracStr.substring(0, 6).replaceAll(RegExp(r'0+$'), '');
    final display = trimmed.isEmpty ? '' : '.$trimmed';
    return '$integerPart$display ETH';
  } else {
    // Integer part is zero — show first 6 significant digits
    final trimmed = fracStr.substring(0, 6).replaceAll(RegExp(r'0+$'), '');
    return '0.$trimmed ETH';
  }
}

/// Formats a wei [BigInt] with thousands separators.
/// Returns `'Unknown'` for `null`.
@visibleForTesting
String formatWei(BigInt? wei) {
  if (wei == null) return 'Unknown';
  final s = wei.toString();
  if (s.length <= 3) return '$s wei';

  final buffer = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    if (count > 0 && count % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
    count++;
  }
  return '${buffer.toString().split('').reversed.join()} wei';
}

// ═══════════════════════════════════════════════════════════════
// Phase 1.5: Calldata Decoding (4-byte selector)
// ═══════════════════════════════════════════════════════════════

/// The result of a successful calldata decode (public for testing).
class DecodedCalldata {
  final String signature;
  final List<String> params;

  const DecodedCalldata({required this.signature, required this.params});
}

/// Decodes a 32-byte chunk from calldata according to [type].
/// - `address`: rightmost 20 bytes → `0x`-prefixed hex
/// - `uint256`: big-endian integer → decimal string
/// - `bytes32`: all 32 bytes → `0x`-prefixed hex
@visibleForTesting
String decodeParam(Uint8List chunk, ParamType type) {
  switch (type) {
    case ParamType.address:
      final addressBytes = chunk.sublist(12);
      final hex = addressBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return '0x$hex';
    case ParamType.uint256:
      var value = BigInt.zero;
      for (final b in chunk) {
        value = (value << 8) | BigInt.from(b);
      }
      return value.toString();
    case ParamType.bytes32:
      final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return '0x$hex';
  }
}

/// Attempts to decode calldata hex string by extracting the 4-byte selector
/// and decoding known parameters.
///
/// Returns `null` if:
/// - Data is too short to contain a selector (< 10 chars = `0x` + 8 hex)
/// - The selector is not in [selectorMap]
@visibleForTesting
DecodedCalldata? tryDecodeCalldata(String? dataHex) {
  if (dataHex == null || dataHex.length < 10) return null;
  final hex = dataHex.startsWith('0x') ? dataHex.substring(2) : dataHex;
  if (hex.length < 8) return null;

  final selectorHex = hex.substring(0, 8);
  final selectorInt = int.tryParse(selectorHex, radix: 16);
  if (selectorInt == null) return null;

  final sig = selectorMap[selectorInt];
  if (sig == null) return null;
  if (sig.paramTypes.isEmpty) {
    return DecodedCalldata(signature: sig.signature, params: const []);
  }

  // Decode parameters — each is 32 bytes (64 hex chars)
  final dataHexOnly = hex.substring(8);
  if (dataHexOnly.length < sig.paramTypes.length * 64) {
    return DecodedCalldata(signature: sig.signature, params: []);
  }

  final params = <String>[];
  for (var i = 0; i < sig.paramTypes.length; i++) {
    final start = i * 64;
    final end = start + 64;
    if (end > dataHexOnly.length) break;
    final paramHex = dataHexOnly.substring(start, end);
    final bytes = Uint8List.fromList(List.generate(
      32,
      (j) => int.parse(paramHex.substring(j * 2, j * 2 + 2), radix: 16),
    ));
    params.add(decodeParam(bytes, sig.paramTypes[i]));
  }

  return DecodedCalldata(signature: sig.signature, params: params);
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.1: Reusable Card Widget
// ═══════════════════════════════════════════════════════════════

/// A flat card section with an optional header label, content [Widget], and
/// an optional copy icon that copies [copyValue] to the clipboard and shows
/// a SnackBar.
class _TransactionReviewCard extends StatelessWidget {
  const _TransactionReviewCard({
    required this.label,
    required this.content,
    this.copyValue,
  });

  final String label;
  final Widget content;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: RedoubtTokens.courtyard,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: RedoubtTokens.lightBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: RedoubtTokens.secondary,
                ),
              ),
              if (copyValue != null)
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: copyValue!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.copy, size: 16),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          content,
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.2: Data Type Header Badge
// ═══════════════════════════════════════════════════════════════

/// A colored badge showing the transaction data type.
/// - `transaction` → `'TRANSACTION'`
/// - `typedData` → `'EIP-712'`
/// - `personalMessage` → `'MESSAGE'`
class _DataHeaderBadge extends StatelessWidget {
  const _DataHeaderBadge({required this.dataType});

  final EthSignDataType dataType;

  String get _label {
    switch (dataType) {
      case EthSignDataType.transaction:
        return 'TRANSACTION';
      case EthSignDataType.typedTransaction:
        return 'TRANSACTION';
      case EthSignDataType.typedData:
        return 'EIP-712';
      case EthSignDataType.personalMessage:
        return 'MESSAGE';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: RedoubtTokens.vaultAccent,
      child: Text(
        _label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.3: Address Card
// ═══════════════════════════════════════════════════════════════

/// Displays an abbreviated address with a copy-to-clipboard icon.
class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address});

  final String? address;

  @override
  Widget build(BuildContext context) {
    return _TransactionReviewCard(
      label: 'Recipient',
      copyValue: address,
      content: SelectableText(
        abbreviateAddress(address),
        style: const TextStyle(
          fontFamily: RedoubtTokens.monoFamily,
          fontSize: 14,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.4: Value / Amount Card
// ═══════════════════════════════════════════════════════════════

/// Displays the ETH amount as a large primary value and the raw wei amount
/// as a smaller secondary line.
class _ValueCard extends StatelessWidget {
  const _ValueCard({required this.wei});

  final BigInt? wei;

  @override
  Widget build(BuildContext context) {
    return _TransactionReviewCard(
      label: 'Amount',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatEth(wei),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            formatWei(wei),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.5: Data / Calldata Card
// ═══════════════════════════════════════════════════════════════

/// Displays transaction data (calldata). If the data matches a known 4-byte
/// selector, shows the decoded function signature and parameters. Otherwise
/// shows collapsed hex (first 40 hex chars + "… [show all]") with an expand
/// toggle.
class _DataCard extends StatelessWidget {
  const _DataCard({required this.dataHex});

  final String? dataHex;

  @override
  Widget build(BuildContext context) {
    final decoded = tryDecodeCalldata(dataHex);

    if (decoded != null) {
      return _TransactionReviewCard(
        label: 'Data',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              decoded.signature,
              style: const TextStyle(
                fontFamily: RedoubtTokens.monoFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (decoded.params.isNotEmpty) const SizedBox(height: 8),
            ...decoded.params.asMap().entries.map((entry) {
              final i = entry.key;
              final param = entry.value;
              final paramLabel = param.startsWith('0x') ? 'Address' : 'Value';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        '$paramLabel ${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        param.startsWith('0x') && param.length > 12
                            ? abbreviateAddress(param)
                            : param,
                        style: const TextStyle(
                          fontFamily: RedoubtTokens.monoFamily,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      );
    }

    return _CollapsedHex(dataHex: dataHex);
  }
}

/// A collapsed hex view with an expand/collapse toggle.
/// Shows the first 40 hex characters + "… [show all]", tap to reveal full.
class _CollapsedHex extends StatefulWidget {
  const _CollapsedHex({required this.dataHex});

  final String? dataHex;

  @override
  State<_CollapsedHex> createState() => _CollapsedHexState();
}

class _CollapsedHexState extends State<_CollapsedHex> {
  bool _showingFull = false;

  @override
  Widget build(BuildContext context) {
    final hex = widget.dataHex ?? 'Unknown';
    final collapsed = hex.length > 42 ? '${hex.substring(0, 42)}…' : hex;
    return _TransactionReviewCard(
      label: 'Data',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            _showingFull ? hex : collapsed,
            style: const TextStyle(
              fontFamily: RedoubtTokens.monoFamily,
              fontSize: 12,
            ),
          ),
          if (hex.length > 42)
            TextButton(
              onPressed: () {
                setState(() => _showingFull = !_showingFull);
              },
              child: Text(_showingFull ? 'Hide' : 'Show all'),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Phase 2.6: Chain / Network Card
// ═══════════════════════════════════════════════════════════════

/// Displays the chain/network name with the numeric chain ID as a subtext.
class _ChainCard extends StatelessWidget {
  const _ChainCard({required this.chainId});

  final int? chainId;

  @override
  Widget build(BuildContext context) {
    final name = chainName(chainId);
    return _TransactionReviewCard(
      label: 'Network',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (chainId != null)
            Text(
              'Chain ID: $chainId',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
        ],
      ),
    );
  }
}