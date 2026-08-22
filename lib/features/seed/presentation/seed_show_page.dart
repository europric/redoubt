import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';

import '../domain/mnemonic.dart';
import 'widgets/word_grid.dart';

/// Displays a freshly generated mnemonic for the user to record
/// (route `/generate/show`).
///
/// `seed-exposure-protection` spec's no-clipboard-copy-ever requirement:
/// NO copy-to-OS-pasteboard affordance exists on this screen — no button,
/// no long-press menu, no share sheet — and
/// the phrase is rendered with plain, non-selectable [Text] widgets (see
/// this file's own structural test, which greps for the forbidden widget
/// and API shapes by name so a future edit cannot reintroduce one
/// silently). Words render as a numbered 3-column by 8-row grid via the
/// shared [WordGrid]/[WordCell] (design.md D6, `critical-screen-ux`'s
/// "Seed Word Grid Display" requirement) -- `masked: false` always, since
/// this screen shows the phrase in the clear (masking is seed-verify's).
///
/// Wrapped in [SecureScreen] per the same spec's "Screenshot And
/// Screen-Recording Protection" requirement.
class SeedShowPage extends StatelessWidget {
  const SeedShowPage({
    super.key,
    required this.mnemonic,
    required this.onContinue,
    this.introText = _defaultIntroText,
    this.continueLabel = 'I have written it down',
  });

  static const _defaultIntroText =
      'Write these 24 words down in order and keep them somewhere safe. '
      'Anyone with this phrase can access your funds.';

  final Mnemonic mnemonic;
  final VoidCallback onContinue;

  /// The instructional copy shown above the word list. Defaults to the
  /// first-time-generation copy; the reveal-seed flow
  /// (`reveal_seed_show_page.dart`) passes different copy for re-viewing an
  /// already-recorded phrase.
  final String introText;

  /// The confirm button's label. Defaults to the first-time-generation
  /// copy; the reveal-seed flow passes "Done" instead.
  final String continueLabel;

  @override
  Widget build(BuildContext context) {
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Your Recovery Phrase')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(introText, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: WordGrid(
                      count: mnemonic.words.length,
                      cell: (context, i) => WordCell(
                        index: i,
                        word: mnemonic.words[i],
                        masked: false,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: onContinue, child: Text(continueLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
