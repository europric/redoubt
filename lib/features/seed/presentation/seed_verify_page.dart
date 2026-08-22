import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';

import 'seed_verify_controller.dart';
import 'widgets/word_grid.dart';

/// Re-entry verification screen (route `/generate/verify`). Wrapped in
/// [SecureScreen] per `seed-exposure-protection` spec — this screen
/// renders word-position labels drawn from the mnemonic, so it qualifies
/// as one of the phrase-adjacent screens the spec calls out by name
/// ("verify-re-entry").
///
/// **`ListenableBuilder` replaces the listener bridge
/// (seed-verify-controller-migration, 2c-2, design.md D2/D3)**: remains a
/// `StatefulWidget` — a documented exception to the `AccountPage`
/// bare-`ListenableBuilder` idiom, now for a second reason too
/// (`ui-redesign` PR3, design.md D5): it owns `Map<int, String> _filled` +
/// `int? _selectedIndex`, the ephemeral chip-selection state for its
/// `WordGrid` + chip-bank interaction. Only the controller-driven tail
/// (error text + the `Verify` button) is wrapped in a bare
/// `ListenableBuilder` — the grid, chip bank, and static copy stay outside
/// it, so filled slots survive a controller notification untouched.
///
/// **D4's consequence (challenge indexes are no longer a pure function of
/// word count)**: `/generate/verify`'s `GoRoute.builder` constructs a new
/// [SeedVerifyController] on every router rebuild, and that controller may
/// now select a genuinely DIFFERENT index set even for the same mnemonic
/// (random, not deterministic). [didUpdateWidget] therefore resets
/// [_filled]/[_selectedIndex] whenever [SeedVerifyController.challengeIndexes]
/// differs from the previous controller's, on top of re-wiring the
/// [_wireVerified] one-shot.
class SeedVerifyPage extends StatefulWidget {
  const SeedVerifyPage({
    super.key,
    required this.controller,
    required this.onVerified,
  });

  final SeedVerifyController controller;
  final VoidCallback onVerified;

  @override
  State<SeedVerifyPage> createState() => _SeedVerifyPageState();
}

class _SeedVerifyPageState extends State<SeedVerifyPage> {
  /// Challenge index -> the word currently placed in that slot (via a chip
  /// tap). Absent entries render as a masked (dotted) placeholder.
  Map<int, String> _filled = {};

  /// The currently-highlighted target slot a chip tap will fill next, or
  /// `null` once every challenged slot is filled.
  int? _selectedIndex;

  /// The chip bank's display order: the 4 correct challenge words, shuffled
  /// once per controller (session) — never re-shuffled on rebuild, so chips
  /// don't visually jump around as the user fills slots (filled words are
  /// simply filtered out of this fixed order in [build]).
  List<String> _bankOrder = const [];

  @override
  void initState() {
    super.initState();
    _resetForController(widget.controller);
    _wireVerified(widget.controller);
  }

  /// **`didUpdateWidget` re-wiring + reset (design.md D4/D5)**:
  /// `/generate/verify`'s `GoRoute.builder` constructs a *new*
  /// [SeedVerifyController] on every router rebuild. A one-shot subscription
  /// bound only in [initState] would go stale — this re-wires
  /// [_wireVerified] against the current [widget.controller] whenever it is
  /// not identical to the previous one. Separately, since D4 makes
  /// `challengeIndexes` a random (not pure) function, a new controller may
  /// select a different index SET even for the same mnemonic — when that
  /// happens, [_filled]/[_selectedIndex] (keyed to the OLD index set) are no
  /// longer meaningful, so they're reset alongside a fresh [_bankOrder].
  @override
  void didUpdateWidget(SeedVerifyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _wireVerified(widget.controller);
    }
    if (!listEquals(
      widget.controller.challengeIndexes,
      oldWidget.controller.challengeIndexes,
    )) {
      _resetForController(widget.controller);
    }
  }

  void _resetForController(SeedVerifyController controller) {
    _filled = {};
    _selectedIndex = controller.challengeIndexes.isEmpty
        ? null
        : controller.challengeIndexes.first;
    _bankOrder = [
      for (final index in controller.challengeIndexes)
        controller.mnemonic.words[index],
    ]..shuffle();
  }

  /// Registers one terminal continuation on [controller.verified] — NOT a
  /// rebuild-driving listener (that would be the removed bridge). Guarded by
  /// [mounted] since the continuation may fire after this page is popped.
  void _wireVerified(SeedVerifyController controller) {
    controller.verified.then((_) {
      if (mounted) widget.onVerified();
    });
  }

  /// A chip labeled [word] was tapped: fills the currently-selected slot
  /// with it (regardless of whether [word] is actually correct FOR that
  /// slot — correctness is judged only on submit, by
  /// [SeedVerifyController.verify]), removes the chip from the bank, and
  /// advances the target to the next unfilled challenged slot.
  void _onChipTap(String word) {
    final target = _selectedIndex;
    if (target == null) return;
    setState(() {
      _filled = {..._filled, target: word};
      _selectedIndex = _nextUnfilledIndex(after: target);
    });
  }

  /// A grid slot at [index] was tapped: re-targets it (its word, if any,
  /// returns to the chip bank since [_filled] no longer contains it).
  void _onSlotTap(int index) {
    setState(() {
      _filled = {..._filled}..remove(index);
      _selectedIndex = index;
    });
  }

  int? _nextUnfilledIndex({required int after}) {
    final indexes = widget.controller.challengeIndexes;
    final afterPosition = indexes.indexOf(after);
    for (var pos = afterPosition + 1; pos < indexes.length; pos++) {
      if (!_filled.containsKey(indexes[pos])) return indexes[pos];
    }
    for (final index in indexes) {
      if (!_filled.containsKey(index)) return index;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final challengeSet = controller.challengeIndexes.toSet();
    final bankWords = _bankOrder
        .where((word) => !_filled.containsValue(word))
        .toList();

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Verify Your Recovery Phrase')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Tap the word for each highlighted position to confirm '
                  'you wrote them down correctly.',
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        WordGrid(
                          count: controller.mnemonic.words.length,
                          // The 20 NON-challenged positions are the ones
                          // hidden behind the dotted placeholder -- they're
                          // not being tested, so there's nothing to show.
                          // The 4 challenged positions are the fill-in
                          // targets: blank until tapped, then reveal the
                          // word the user placed there.
                          cell: (context, index) {
                            if (!challengeSet.contains(index)) {
                              return WordCell(index: index, masked: true);
                            }
                            final filledWord = _filled[index];
                            return WordCell(
                              index: index,
                              word: filledWord,
                              selected: _selectedIndex == index,
                              challenged: true,
                              onTap: () => _onSlotTap(index),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final word in bankWords)
                              ActionChip(
                                label: Text(word),
                                onPressed: () => _onChipTap(word),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final state = controller.verifyState;
                    final allFilled =
                        _filled.length == controller.challengeIndexes.length;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.errorOrNull != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 8),
                            child: Text(
                              state.errorOrNull!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: (allFilled && !state.isLoading)
                              ? () => controller.verify(_filled)
                              : null,
                          child: const Text('Verify'),
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
