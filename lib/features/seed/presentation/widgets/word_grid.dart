/// Shared 3-column x 8-row (24-cell) word grid -- used by seed show/generate
/// display and (PR3) seed verify (design.md D1: intra-`features/seed`
/// sharing only, never `lib/core/`).
///
/// [WordGrid] measures ONE font size, shared by every cell, from a fixed
/// worst-case word rather than from whatever words the caller actually
/// passes: the mnemonic is always drawn from the 2048-word BIP-39 English
/// wordlist (`blockchain_utils`' `word_list.dart`, already a dependency),
/// whose longest word is 8 characters (e.g. "abstract", "accident") -- no
/// word in that fixed list can ever be longer, so measuring against it
/// guarantees no cell overflows regardless of which 24 words are actually
/// rendered (design.md D6). **Rejected**: per-cell `FittedBox` (each cell
/// scales independently -> visually inconsistent text sizes across the
/// grid); an auto-size package (a new dependency in an air-gapped wallet).
library;

import 'package:flutter/material.dart';

const _columns = 3;
const _gridSpacing = 8.0;
const _cellPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);
const _maxCellFontSize = 16.0;
const _minCellFontSize = 10.0;
const _fontStep = 0.5;
const _indexLabelFontSize = 10.0;

/// Longest word across the BIP-39 English wordlist (2048 words) -- measured
/// once to size every [WordCell] in a [WordGrid] identically, regardless of
/// the actual words rendered (see library doc).
const kLongestBip39Word = 'abstract';

/// What a [WordCell] shows instead of its word when [WordCell.masked] is
/// `true` (seed-verify's dotted placeholders, PR3).
const kMaskedWordPlaceholder = '••••••';

class WordGrid extends StatelessWidget {
  const WordGrid({super.key, required this.count, required this.cell});

  /// Total number of cells to render (24 for a full BIP-39 mnemonic).
  final int count;

  /// Builds the widget for cell [index] (0-based). Typically a [WordCell].
  final Widget Function(BuildContext context, int index) cell;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth =
            (constraints.maxWidth - _gridSpacing * (_columns - 1)) / _columns;
        final fontSize = _measureFontSize(context, cellWidth);

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisSpacing: _gridSpacing,
            crossAxisSpacing: _gridSpacing,
            childAspectRatio: 2.6,
          ),
          itemCount: count,
          itemBuilder: (context, index) => DefaultTextStyle.merge(
            style: TextStyle(fontSize: fontSize),
            child: cell(context, index),
          ),
        );
      },
    );
  }

  /// Measures [kLongestBip39Word] with a [TextPainter], shrinking from
  /// [_maxCellFontSize] until it fits [cellWidth] minus [_cellPadding]'s
  /// horizontal inset -- the same padding [WordCell] renders with, so this
  /// measurement is exact, not a heuristic guess.
  double _measureFontSize(BuildContext context, double cellWidth) {
    final availableWidth = cellWidth - _cellPadding.horizontal;
    final baseStyle = DefaultTextStyle.of(context).style;

    for (
      var fontSize = _maxCellFontSize;
      fontSize > _minCellFontSize;
      fontSize -= _fontStep
    ) {
      final painter = TextPainter(
        text: TextSpan(
          text: kLongestBip39Word,
          style: baseStyle.copyWith(fontSize: fontSize),
        ),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      if (painter.width <= availableWidth) return fontSize;
    }
    return _minCellFontSize;
  }
}

/// One [WordGrid] cell: a numbered word, optionally [masked] (dots instead
/// of [word] -- seed-verify's dotted placeholders, PR3), [challenged] (a
/// stronger, near-black outline -- seed-verify's 3 other fill-in targets,
/// PR3), or [selected] (a `colorScheme.tertiary` accent outline --
/// seed-verify's current target slot, PR3; wins over [challenged] when both
/// are true. `redoubt-visual-identity` design.md D6: NOT `colorScheme.
/// primary`, which under `AppTheme.light` equals `colorScheme.onSurface`
/// and would collapse into [challenged]'s color).
/// Renders as plain [Text] in [MergeSemantics] -- never `SelectableText` --
/// so no seed word is ever copy-selectable (`critical-screen-ux`'s "No
/// clipboard or selectable-text exposure of seed words" scenario holds by
/// construction for every [WordGrid] caller).
///
/// The index label sits in a [Stack] corner rather than inline before the
/// word (as the previous `_WordChip` did): an inline prefix's width varies
/// with the index ("1." vs "24."), which would eat into the word's
/// available width in a way [WordGrid]'s font-size measurement does not
/// account for. A corner label keeps the word's available width -- and
/// therefore the measurement -- exact for every cell.
class WordCell extends StatelessWidget {
  const WordCell({
    super.key,
    required this.index,
    this.word,
    this.masked = false,
    this.selected = false,
    this.challenged = false,
    this.onTap,
  });

  /// 0-based position in the mnemonic; rendered as `index + 1`.
  final int index;

  /// The word to display. `null` renders an empty placeholder cell.
  final String? word;

  /// When `true`, renders [kMaskedWordPlaceholder] instead of [word].
  final bool masked;

  /// When `true`, outlines the cell with `colorScheme.tertiary` (the accent
  /// -- design.md D6).
  final bool selected;

  /// When `true` (and not [selected]), outlines the cell with
  /// `colorScheme.onSurface` instead of the default subtle
  /// `outlineVariant` -- seed-verify's 3 not-yet-targeted challenge slots,
  /// so all 4 fill-in targets read as a group distinct from the 20
  /// non-challenged cells, with [selected] still marking the current one.
  final bool challenged;

  /// Invoked when the cell is tapped, if provided.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return MergeSemantics(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: _cellPadding,
          decoration: BoxDecoration(
            // design.md D6: under AppTheme.light, `primary == onSurface`
            // (both `wall` #16181A) -- selected can no longer share
            // `colorScheme.primary` with the challenged slots below it, or
            // the two states become visually identical, breaking
            // seed-verify's chip-bank UX. `tertiary` (the accent) marks the
            // one active element per view, per components.md; unselected
            // moves to `outline` (`outlineVariant` on `courtyard` is
            // ~1.1:1, nearly invisible).
            border: Border.all(
              color: selected
                  ? colorScheme.tertiary
                  : challenged
                  ? colorScheme.onSurface
                  : colorScheme.outline,
              width: selected || challenged ? 2 : 1,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 0,
                left: 0,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: _indexLabelFontSize,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                masked ? kMaskedWordPlaceholder : (word ?? ''),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
