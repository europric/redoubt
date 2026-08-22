/// First step of the first-run onboarding sequence — `onboarding-flow`
/// spec's "Three-Step Guided Sequence For First-Ever Setup" requirement: a
/// brief app-purpose explainer shown before biometric enrollment and PIN
/// setup.
///
/// Deliberately a "dumb" callback widget, mirroring
/// `SeedSetupChoicePage`'s `onGenerate`/`onImport` convention: this page does
/// NOT itself write `onboarding.intro.seen.v1` or decide the next route
/// (biometric step vs. skipping straight to PIN setup when unsupported) —
/// both happen at the composition root (`app_router.dart`'s
/// `onboarding.intro` route), matching this codebase's existing pattern of
/// keeping business-logic wiring out of presentation widgets.
library;

import 'package:flutter/material.dart';

class OnboardingIntroPage extends StatelessWidget {
  const OnboardingIntroPage({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.account_balance_wallet_outlined, size: 96),
              const SizedBox(height: 24),
              const Text(
                'Your keys, your crypto',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'This app stores your wallet seed securely on this device '
                'only, never on a server. Next, you will set up a PIN — and '
                'optionally biometrics — to protect it.',
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                key: const Key('onboardingContinueButton'),
                onPressed: onContinue,
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
