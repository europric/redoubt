/// The `app-unlock-gate` screen (route `/unlock`, biometric-unlock-onboarding
/// design.md's Data Flow diagram): composes [AppUnlockController] +
/// [PinEntryPage] + the retry key. Biometric-first -- an automatic
/// [AppUnlockController.attemptBiometric] fires once, at mount, via
/// [ControllerHost.onAttach] -- with immediate PIN fallback the moment
/// biometrics are unenrolled, denied, cancelled, or fail (D2: never blocked
/// by any backoff/lockout).
///
/// Same "factory, not a live instance" convention as `/account/scan`'s
/// `createController` (`state-management-foundation` design.md): a fresh
/// [AppUnlockController] is constructed exactly once per mount, never
/// re-constructed on a router rebuild that does not unmount this widget.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

import 'app_unlock_controller.dart';
import 'pin_entry_page.dart';

class AppUnlockPage extends StatelessWidget {
  const AppUnlockPage({
    super.key,
    required this.createController,
    required this.onUnlocked,
    required this.onVaultUnreadable,
  });

  final AppUnlockController Function() createController;

  /// Invoked once, after either a successful biometric attempt or a
  /// correct PIN submission. This page never navigates itself -- the
  /// caller (`app_router.dart`'s `/unlock` route) owns
  /// `markUnlocked()`/redirect behavior.
  final VoidCallback onUnlocked;

  /// Invoked when the stored blob is malformed or an unrecognized version
  /// (`MalformedVaultBlobFailure`/`UnsupportedVaultVersionFailure`) --
  /// mirrors `signPin`/`revealSeedPin`/`deleteAccountPin`'s existing
  /// recovery-routing convention: the caller should re-probe `VaultState`
  /// (`VaultScope.refreshVaultState()`) so the router's own redirect guard
  /// takes over, rather than offering a PIN retry for a structurally broken
  /// blob.
  final Future<void> Function() onVaultUnreadable;

  Future<void> _attemptBiometric(
    BuildContext context,
    AppUnlockController controller,
  ) async {
    await controller.attemptBiometric();
    if (!context.mounted) return;
    if (controller.state case AsyncData<bool>(value: true)) {
      onUnlocked();
    }
  }

  Future<void> _submitPin(
    BuildContext context,
    AppUnlockController controller,
    Uint8List pin,
  ) async {
    try {
      await controller.submitPin(pin);
    } on MalformedVaultBlobFailure {
      await onVaultUnreadable();
      return;
    } on UnsupportedVaultVersionFailure {
      await onVaultUnreadable();
      return;
    }

    if (controller.state case AsyncData<bool>(value: true)) {
      onUnlocked();
      return;
    }

    final error = controller.state.errorOrNull;
    if (error != null) throw PinRejectedFailure(error);
  }

  @override
  Widget build(BuildContext context) {
    return ControllerHost<AppUnlockController>(
      create: createController,
      onAttach: (context, controller) => _attemptBiometric(context, controller),
      builder: (context, controller) {
        if (!controller.showPinFallback) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return PinEntryPage(
          unlockThrottle: controller.unlockThrottle,
          onSubmit: (pin) => _submitPin(context, controller, pin),
          onBiometricRetry: controller.biometricEnabled
              ? () => _attemptBiometric(context, controller)
              : null,
          biometricKind: controller.biometricKind,
        );
      },
    );
  }
}
