/// Late biometric enrollment entry point (route `/account/security`,
/// biometric-unlock-onboarding design.md D6: "Late enrollment reuses
/// onboarding's controller"). Composes the SAME [BiometricEnrollmentController]
/// `/onboarding/biometric` uses — no second enrollment mechanism.
///
/// `onboarding-flow` spec's "Late Biometric Enrollment Via A Settings Entry
/// Point" requirement: the "enable biometric unlock" affordance is visible
/// ONLY when the device supports biometrics AND they are not yet enrolled
/// ([BiometricEnrollmentStatus.declined]) — hidden entirely for
/// [BiometricEnrollmentStatus.unsupported] (no hardware) and
/// [BiometricEnrollmentStatus.enabled] (already enrolled, nothing left to
/// offer as a fresh enrollment).
library;

import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/features/vault/vault.dart';

class SecuritySettingsPage extends StatelessWidget {
  const SecuritySettingsPage({super.key, required this.createController});

  /// A factory, not a live instance — same "one controller per mount"
  /// convention as `/account/scan`'s `createController` and `/unlock`'s
  /// `AppUnlockPage`.
  final BiometricEnrollmentController Function() createController;

  @override
  Widget build(BuildContext context) {
    return ControllerHost<BiometricEnrollmentController>(
      create: createController,
      onAttach: (context, controller) => controller.load(),
      builder: (context, controller) {
        return Scaffold(
          appBar: AppBar(title: const Text('Security')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: switch (controller.state) {
                AsyncIdle<BiometricEnrollmentStatus>() ||
                AsyncLoading<BiometricEnrollmentStatus>() => const Center(
                  child: CircularProgressIndicator(),
                ),
                AsyncData<BiometricEnrollmentStatus>(:final value) =>
                  _StatusView(status: value, controller: controller),
                AsyncError<BiometricEnrollmentStatus>(:final message) => Center(
                  child: Text(message),
                ),
              },
            ),
          ),
        );
      },
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.status, required this.controller});

  final BiometricEnrollmentStatus status;
  final BiometricEnrollmentController controller;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      // Entry point hidden entirely — no biometric hardware wrap on this
      // device at all.
      BiometricEnrollmentStatus.unsupported => const Text(
        "This device doesn't support biometric unlock.",
      ),
      // Entry point hidden — nothing left to offer as a fresh enrollment.
      BiometricEnrollmentStatus.enabled => const Text(
        'Biometric unlock is enabled.',
      ),
      BiometricEnrollmentStatus.declined => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Use your fingerprint or face to unlock the app faster, '
            'without typing your PIN every time.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('enableBiometricUnlockButton'),
            onPressed: controller.enable,
            child: const Text('Enable biometric unlock'),
          ),
        ],
      ),
    };
  }
}
