import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';

import '../domain/mnemonic.dart';
import 'seed_generate_controller.dart';
import 'widgets/passphrase_opt_in_field.dart';

/// Entry point of the "create a new vault" flow (route `/generate`).
/// Presentational container: owns [controller], calls [onGenerated] with
/// the freshly generated mnemonic so the router can navigate to
/// `SeedShowPage` (Phase 6 wiring — out of scope for this PR).
///
/// **Passphrase opt-in (seed-passphrase-25th-word design.md D3/D6)**: hosts
/// the shared [PassphraseOptInField] (`requireConfirmation: true`) below the
/// Generate button. Unchecked by default — no passphrase field renders and
/// the pre-existing explainer/button tree is unaffected
/// (`critical-screen-ux` spec's "Disclosure-Neutral Passphrase Toggle"
/// requirement). A valid opted-in value is written into [draft] via
/// `OnboardingDraft.setPassphrase()` BEFORE [onGenerated] fires — this is
/// the ONLY write point; `SeedVerifyController` (three routes later) reads
/// it back via `takePassphrase()` at the real commit.
class SeedGeneratePage extends StatefulWidget {
  const SeedGeneratePage({
    super.key,
    required this.controller,
    required this.draft,
    required this.onGenerated,
  });

  final SeedGenerateController controller;
  final OnboardingDraft draft;
  final ValueChanged<Mnemonic> onGenerated;

  @override
  State<SeedGeneratePage> createState() => _SeedGeneratePageState();
}

class _SeedGeneratePageState extends State<SeedGeneratePage> {
  Uint8List? _passphraseUtf8;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create a New Vault')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'A new 24-word recovery phrase will be generated on this '
                'device. Nothing is saved until you confirm it.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  final passphrase = _passphraseUtf8;
                  if (passphrase != null) {
                    widget.draft.setPassphrase(passphrase);
                  }
                  widget.controller.generate();
                  widget.onGenerated(widget.controller.mnemonic!);
                },
                child: const Text('Generate'),
              ),
              PassphraseOptInField(
                requireConfirmation: true,
                onChanged: (value) => _passphraseUtf8 = value,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
