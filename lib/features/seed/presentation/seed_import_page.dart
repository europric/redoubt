import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';

import 'seed_import_controller.dart';
import 'widgets/passphrase_opt_in_field.dart';

/// "Import an existing phrase" screen (route `/import`). Wrapped in
/// [SecureScreen] like every phrase-adjacent screen. Unlike
/// `SeedShowPage`, there is no restriction on *pasting into* the entry
/// field — the clipboard prohibition in `seed-exposure-protection` spec
/// is specifically about not letting the app's own generated/displayed
/// phrase be copied OUT; a user pasting a phrase they already have
/// elsewhere is unrelated and unrestricted here.
///
/// **`ListenableBuilder` replaces the listener bridge
/// (seed-import-controller-migration, 2c-1, design.md D2/D3)**: remains a
/// `StatefulWidget` — a documented exception to the `AccountPage`
/// bare-`ListenableBuilder` idiom, since this page must retain a
/// `TextEditingController` for the phrase field and therefore cannot become
/// `StatelessWidget` + `ControllerHost`. Only the controller-driven tail
/// (error text + the `Import` button) is wrapped in a bare
/// `ListenableBuilder` — the `TextField` and static copy stay outside it,
/// so entered text survives a controller notification untouched.
///
/// **Passphrase opt-in (seed-passphrase-25th-word design.md D3/D6)**: hosts
/// the shared [PassphraseOptInField] (`requireConfirmation: true`) below
/// the phrase field. The Import button writes a valid passphrase into
/// [draft] BEFORE calling [SeedImportController.import] — same order as
/// `SeedGeneratePage` — and rolls the write back via
/// `OnboardingDraft.clearPassphrase()` if the import turns out invalid, so
/// a failed attempt still never leaves a stray passphrase in the draft.
///
/// **Race-condition fix (seed-import-passphrase-race-fix, confirmed via
/// real-device repro)**: writing the passphrase AFTER `await
/// controller.import(...)` (the original design) was unsafe.
/// [SeedImportController.import] completes an internal `Completer`
/// (`imported`) whose listener is the ROUTER's own `onImported` callback
/// (`app_router.dart`'s `import` route) — when onboarding already holds a
/// PIN, that callback commits immediately via `commitWithDraft()`, which
/// reads `draft.takePassphrase()` synchronously. Dart schedules that
/// Completer listener as a microtask at the moment `import()` completes it
/// — BEFORE this page's own `await import(...)` continuation resumes — so
/// a post-await `draft.setPassphrase(...)` arrived too late for the
/// fast-path commit to see it, silently committing with an empty
/// passphrase. Writing it first (and rolling back on failure) closes that
/// window structurally rather than by timing.
class SeedImportPage extends StatefulWidget {
  const SeedImportPage({
    super.key,
    required this.controller,
    required this.draft,
    required this.onImported,
  });

  final SeedImportController controller;
  final OnboardingDraft draft;
  final VoidCallback onImported;

  @override
  State<SeedImportPage> createState() => _SeedImportPageState();
}

class _SeedImportPageState extends State<SeedImportPage> {
  final _phraseField = TextEditingController();
  Uint8List? _passphraseUtf8;

  @override
  void initState() {
    super.initState();
    _wireImported(widget.controller);
  }

  /// **`didUpdateWidget` re-wiring (design.md D2, required)**: `/import`'s
  /// `GoRoute.builder` constructs a *new* [SeedImportController] on every
  /// router rebuild (including the rebuild caused by pushing
  /// `/import/pin-setup`, or a pop-back-and-retry). A one-shot subscription
  /// bound only in [initState] would go stale — this re-wires [_wireImported]
  /// against the current [widget.controller] whenever it is not identical
  /// to the previous one, fixing that latent bug.
  @override
  void didUpdateWidget(SeedImportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _wireImported(widget.controller);
    }
  }

  /// Registers one terminal continuation on [controller.imported] — NOT a
  /// rebuild-driving listener (that would be the removed bridge). Guarded by
  /// [mounted] since the continuation may fire after this page is popped.
  void _wireImported(SeedImportController controller) {
    controller.imported.then((_) {
      if (mounted) widget.onImported();
    });
  }

  @override
  void dispose() {
    _phraseField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Import Recovery Phrase')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Enter your 12-24 word recovery phrase, separated by '
                  'spaces.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _phraseField,
                  maxLines: 4,
                  // #29: never surface a recovery phrase to the keyboard's
                  // spell-check/suggestion service.
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Recovery phrase',
                  ),
                ),
                PassphraseOptInField(
                  requireConfirmation: true,
                  onChanged: (value) => _passphraseUtf8 = value,
                ),
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) {
                    final state = widget.controller.importState;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.errorOrNull != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              state.errorOrNull!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: state.isLoading
                              ? null
                              : () async {
                                  // Written BEFORE import(), not after
                                  // (race-condition fix): import()
                                  // completes a Completer whose listener
                                  // is the ROUTER's own onImported
                                  // callback (app_router.dart's
                                  // `import` route) — when onboarding
                                  // already holds a PIN, that callback
                                  // commits immediately via
                                  // commitWithDraft(), reading
                                  // draft.takePassphrase() synchronously.
                                  // Dart schedules that Completer
                                  // listener as a microtask BEFORE this
                                  // handler's own continuation past
                                  // `await import(...)` resumes, so
                                  // writing the passphrase after the
                                  // await arrived too late for the
                                  // fast-path commit to see it (confirmed
                                  // via real-device repro: the commit
                                  // silently used an empty passphrase).
                                  // If import() turns out invalid, the
                                  // speculative write is undone below —
                                  // clearPassphrase() only, not clear(),
                                  // so an onboarding-collected PIN
                                  // survives a failed import attempt.
                                  final passphrase = _passphraseUtf8;
                                  if (passphrase != null) {
                                    widget.draft.setPassphrase(passphrase);
                                  }
                                  await widget.controller.import(
                                    _phraseField.text,
                                  );
                                  if (passphrase != null &&
                                      widget
                                              .controller
                                              .importState
                                              .dataOrNull ==
                                          null) {
                                    widget.draft.clearPassphrase();
                                  }
                                },
                          child: const Text('Import'),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
