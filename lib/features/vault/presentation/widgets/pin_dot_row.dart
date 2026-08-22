/// Shared PIN dot-progress indicator — used by both `pin_setup_page.dart`
/// and `pin_entry_page.dart` (design.md D1: intra-`features/vault` sharing
/// only, never `lib/core/`).
///
/// [PinDotRow] receives ONE digit at a time via [revealChar], never the
/// whole PIN (design.md D2) — the caller owns the actual PIN value as a
/// plain `String`. On a [filledCount] increase this widget briefly shows
/// [revealChar] at the newly-filled index, then reverts to a full-opacity
/// dot after [kPinRevealDuration] (350ms, design.md D3 — long enough that
/// the last reveal is not visually cut off). Unfilled dots render dimmed.
///
/// The reveal timer is owned here (not duplicated per page, design.md D2's
/// rejected alternative) and is `mounted`-guarded + cancelled in [dispose].
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// How long a just-entered digit is shown before reverting to a plain dot.
/// Long enough that the last-entered digit isn't visually cut off before
/// the 6th-digit auto-advance fires (design.md D3).
const kPinRevealDuration = Duration(milliseconds: 350);

class PinDotRow extends StatefulWidget {
  const PinDotRow({
    super.key,
    this.length = 6,
    required this.filledCount,
    this.revealChar,
  });

  /// Total number of dots to render.
  final int length;

  /// How many dots are currently filled.
  final int filledCount;

  /// The single digit just entered at index `filledCount - 1`, shown
  /// briefly before reverting to a dot. Never the whole PIN.
  final String? revealChar;

  @override
  State<PinDotRow> createState() => _PinDotRowState();
}

class _PinDotRowState extends State<PinDotRow> {
  Timer? _revealTimer;
  int? _revealingIndex;

  @override
  void didUpdateWidget(covariant PinDotRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filledCount > oldWidget.filledCount) {
      _revealTimer?.cancel();
      _revealingIndex = widget.filledCount - 1;
      _revealTimer = Timer(kPinRevealDuration, () {
        if (!mounted) return;
        setState(() => _revealingIndex = null);
      });
    } else if (widget.filledCount < oldWidget.filledCount) {
      _revealTimer?.cancel();
      _revealingIndex = null;
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.length, (index) {
        final filled = index < widget.filledCount;
        final revealing = index == _revealingIndex;

        // Both branches sit inside the same fixed 20x20 box (instead of the
        // dot sizing itself to a smaller 12x12 `Container`) so switching
        // between them never changes this cell's -- or the whole row's --
        // height. A per-dot size mismatch previously made the row (and
        // everything below it) jump vertically on every keypress.
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 20,
            height: 20,
            child: Center(
              child: revealing
                  ? Transform.translate(
                      offset: const Offset(0, -1),
                      child: Text(
                        widget.revealChar ?? '',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          height: 1,
                          color: onSurface,
                        ),
                      ),
                    )
                  : Opacity(
                      key: ValueKey('pin-dot-opacity-$index'),
                      opacity: filled ? 1.0 : 0.3,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: onSurface,
                        ),
                      ),
                    ),
            ),
          ),
        );
      }),
    );
  }
}
