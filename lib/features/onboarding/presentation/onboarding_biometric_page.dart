/// Second step of the first-run onboarding sequence — `onboarding-flow`
/// spec's "Skipping the biometric step still proceeds to PIN setup"
/// scenario. Only ever reached when `AuthService.isSupported()` is true —
/// the composition root (`app_router.dart`'s `onboarding.intro` route)
/// skips straight to `/onboarding/pin` on an unsupported device, so this
/// page itself never needs to render an "unsupported" state.
///
/// Deliberately a "dumb" callback widget (same convention as
/// `OnboardingIntroPage`): [onEnable] is wired by `app_router.dart` to
/// `BiometricEnrollmentController.enable()` followed by navigation to
/// `/onboarding/pin` regardless of the prompt's outcome; [onSkip] navigates
/// there directly, without ever touching the controller — biometric
/// enrollment is never mandatory to reach PIN setup.
library;

import 'package:flutter/material.dart';

class OnboardingBiometricPage extends StatelessWidget {
  const OnboardingBiometricPage({
    super.key,
    required this.onEnable,
    required this.onSkip,
  });

  final VoidCallback onEnable;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enable biometric unlock')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.fingerprint, size: 96),
              const SizedBox(height: 24),
              const Text(
                'Use your fingerprint or face to unlock the app faster, '
                'without typing your PIN every time.',
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                key: const Key('onboardingEnableBiometricButton'),
                onPressed: onEnable,
                child: const Text('Enable'),
              ),
              const SizedBox(height: 12),
              TextButton(
                key: const Key('onboardingSkipBiometricButton'),
                onPressed: onSkip,
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
