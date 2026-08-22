import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redoubt/core/presentation/presentation.dart';

import 'account_controller.dart';
import 'address_format.dart';
import 'pairing_qr.dart';

/// The Account screen (route `/account`).
///
/// `ethereum-account` spec's "Address Display Without Re-Exposing Seed"
/// requirement: shows ONLY the checksummed `0x` address — never the
/// mnemonic, never a private key, and no add/switch-account affordance
/// exists anywhere on this screen (there is only ever one account,
/// `ethereum-account` spec's "No multi-account affordance" scenario).
///
/// The default QR encodes only the plain address (`depositQr`,
/// `ethereum-account` spec's "Default QR encodes the plain address only"
/// scenario). The `crypto-hdkey` pairing QR
/// (`qr-air-gapped-signing` spec's "Pairing QR Precedes Signing"
/// requirement) via [buildPairingQrUrString] is reachable on demand
/// through a silent FAB dialog only — it never renders unconditionally on
/// screen open — sourced only from [AccountController.state]'s
/// [AccountDetails.pairingKey], never from the seed/mnemonic.
///
/// **`StatelessWidget` + bare `ListenableBuilder`, NOT `ControllerHost`**
/// (account-controller-host design.md, `state-management-foundation`
/// spec's documented exception): [controller] is the sole `ChangeNotifier`
/// singleton on `VaultScope`, owned by neither this widget nor any other —
/// [ControllerHost] would tear it down on unmount, which is exactly the
/// leak this class must NOT introduce (`state-management-foundation` spec's
/// "No AccountController disposal across mount/unmount cycles" scenario).
/// The one-shot `load()` guard that used to live in
/// `initState` now lives in the `/account` `GoRoute.builder`
/// (`app_router.dart`) instead, since this widget has no lifecycle hook to
/// put it in.
class AccountPage extends StatelessWidget {
  const AccountPage({
    super.key,
    required this.controller,
    this.onScanToSign,
    this.onRevealSeed,
    this.onOpenSecuritySettings,
    this.onDeleteAccount,
  });

  final AccountController controller;

  /// Navigates to the Scan screen (route `/account/scan`,
  /// `qr-air-gapped-signing` spec's signing flow). `null` hides the
  /// affordance entirely — e.g. if QR signing is unavailable (the spec's
  /// "Non-Blocking Optionality" requirement).
  final VoidCallback? onScanToSign;

  /// Navigates to the biometric-and-PIN-gated reveal-seed flow (route
  /// `/account/reveal-seed/pin`, `ethereum-account` spec's "Mnemonic still
  /// requires a separate gated flow" scenario). A DIFFERENT, single-
  /// account-scoped affordance from the "no add/switch-account affordance"
  /// scope documented on this class — not a violation of it. `null` hides
  /// the affordance entirely.
  final VoidCallback? onRevealSeed;

  /// Navigates to the late biometric-enrollment settings screen (route
  /// `/account/security`, `onboarding-flow` spec's "Late Biometric
  /// Enrollment Via A Settings Entry Point" requirement). `null` hides the
  /// affordance entirely — same nullable-callback convention as
  /// [onRevealSeed]/[onDeleteAccount].
  final VoidCallback? onOpenSecuritySettings;

  /// Starts the delete-account flow (`account-deletion` spec's "Delete
  /// Affordance Offered Only When Vault State Is Current" requirement):
  /// the `/account` route builder only ever supplies this when `VaultState`
  /// is `current` (the redirect guard never builds `/account` otherwise),
  /// so `null` here doubles as both "hide the affordance" and the
  /// `legacy`/`unreadable`-hides-it scenario, by construction. `null` hides
  /// the affordance entirely.
  final VoidCallback? onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    // Single hoisted `ListenableBuilder` above the `Scaffold` (design.md
    // D7): `floatingActionButton` and `body` both derive from one read of
    // `controller.state`, so the FAB can exist only in the `AsyncData` arm
    // (it needs `details.pairingKey`) without a second listener.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Account'),
            actions: [
              if (onOpenSecuritySettings != null)
                IconButton(
                  key: const Key('openSecuritySettingsButton'),
                  icon: const Icon(Icons.security),
                  tooltip: 'Security',
                  onPressed: onOpenSecuritySettings,
                ),
              if (onDeleteAccount != null)
                IconButton(
                  key: const Key('deleteAccountButton'),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete Account',
                  onPressed: onDeleteAccount,
                ),
            ],
          ),
          // `qr-air-gapped-signing` spec's "Pairing QR does not render on
          // Account screen open" scenario: this FAB is deliberately
          // silent — no tooltip, no first-time hint/onboarding overlay.
          floatingActionButton: switch (state) {
            AsyncData<AccountDetails>(:final value) => FloatingActionButton(
              key: const Key('pairingQrFab'),
              onPressed: () => _showPairingQrDialog(context, value),
              child: const Icon(Icons.qr_code_2),
            ),
            _ => null,
          },
          body: SafeArea(
            child: switch (state) {
              // Idle renders the same spinner as Loading (design.md D7):
              // idle is unreachable in the normal path (the router guard
              // transitions to loading before this widget builds), so
              // this only guards a stray idle frame.
              AsyncIdle<AccountDetails>() || AsyncLoading<AccountDetails>() =>
                const Center(child: CircularProgressIndicator()),
              AsyncData<AccountDetails>(:final value) =>
                // The Card + address + QR content can exceed short
                // viewports (e.g. landscape/small devices); scrollable
                // to avoid a RenderFlex overflow rather than clipping.
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _AccountDetailsView(
                    details: value,
                    onScanToSign: onScanToSign,
                    onRevealSeed: onRevealSeed,
                  ),
                ),
              AsyncError<AccountDetails>(:final message) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(message),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('repairCacheButton'),
                        onPressed: controller.repairCache,
                        child: const Text('Unlock to restore account details'),
                      ),
                    ],
                  ),
                ),
              ),
            },
          ),
        );
      },
    );
  }
}

/// Opens the `qr-air-gapped-signing` spec's pairing QR in a dialog, reached
/// only via the FAB (never rendered on screen open). Reuses
/// [buildPairingQrUrString] unchanged and keeps `Key('pairingQr')` forwarded
/// to the inner `QrImageView` via [QrCodeView.qrKey] (design.md D9) — the
/// same widget that used to render unconditionally on the Account screen
/// body.
void _showPairingQrDialog(BuildContext context, AccountDetails details) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Scan to pair with MetaMask'),
            const SizedBox(height: 8),
            QrCodeView(
              qrKey: const Key('pairingQr'),
              data: buildPairingQrUrString(details.pairingKey),
              semanticsLabel: buildPairingQrUrString(details.pairingKey),
              size: 240,
            ),
          ],
        ),
      ),
    ),
  );
}

class _AccountDetailsView extends StatelessWidget {
  const _AccountDetailsView({
    required this.details,
    required this.onScanToSign,
    required this.onRevealSeed,
  });

  final AccountDetails details;
  final VoidCallback? onScanToSign;
  final VoidCallback? onRevealSeed;

  @override
  Widget build(BuildContext context) {
    final address = details.account.address;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `ethereum-account` spec's truncation + copy-icon requirement
        // (design.md D4/D5): framework `Card` inline, no new widget class.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Address'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      // Full address stays reachable via Semantics for
                      // accessibility, even though only the truncated
                      // form is ever rendered as visible text.
                      child: Semantics(
                        container: true,
                        label: address,
                        child: ExcludeSemantics(
                          child: Text(
                            truncateAddress(address),
                            // Addresses are data, not body copy — rendered
                            // mono via bodySmall (design.md D7).
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('copyAddressButton'),
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy address',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: address));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Address copied')),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Same Card recipe as the signature screen's QR (design.md D4):
        // QR first, caption centered below it, both inside one card.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrCodeView(
                  qrKey: const Key('depositQr'),
                  data: address,
                  semanticsLabel: 'Deposit QR for $address',
                  size: 240,
                ),
                const SizedBox(height: 8),
                const Text('Scan to receive', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
        if (onScanToSign != null) ...[
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('scanToSignButton'),
            onPressed: onScanToSign,
            child: const Text('Scan to Sign'),
          ),
        ],
        if (onRevealSeed != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('revealSeedButton'),
            onPressed: onRevealSeed,
            child: const Text('Reveal Recovery Phrase'),
          ),
        ],
      ],
    );
  }
}
