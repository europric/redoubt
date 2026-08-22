import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';
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
/// `ValueChanged&lt;SignReviewController&gt;`" decision).
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

        return SecureScreen(
          child: Scaffold(
            appBar: AppBar(title: const Text('Review Transaction')),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SummaryRow(
                      label: 'To',
                      value: request.toAddressHex ?? 'Unknown',
                    ),
                    _SummaryRow(
                      label: 'Value (wei)',
                      value: request.valueWei?.toString() ?? 'Unknown',
                    ),
                    _SummaryRow(
                      label: 'Data',
                      value: request.dataHex ?? 'Unknown',
                    ),
                    _SummaryRow(
                      label: 'Chain ID',
                      value: request.chainId?.toString() ?? 'Unknown',
                    ),
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
                      onPressed: isLoading ? null : () => onConfirm(controller),
                      child: isLoading
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
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

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value),
        ],
      ),
    );
  }
}
