import 'package:flutter/material.dart';

import '../domain/mnemonic.dart';
import 'seed_show_page.dart';

/// Hosts [SeedShowPage] for the reveal-seed flow (route
/// `/account/reveal-seed/show`) and zeroizes [mnemonic]'s entropy buffer
/// once this view is left — closing `seed-exposure-protection`'s "Mnemonic
/// buffer zeroized after use" scenario for the reveal-seed path (`Mnemonic`
/// 's own doc comment already anticipated this exact call site).
///
/// `dispose` is the single disposal hook — it runs whether the view is left
/// via [onDone] (tapping the confirm button) or the user navigating away/
/// back (a system back gesture, a route pop), so the buffer is always
/// zeroized exactly once, regardless of how the view was left.
class RevealSeedShowPage extends StatefulWidget {
  const RevealSeedShowPage({
    super.key,
    required this.mnemonic,
    required this.onDone,
  });

  final Mnemonic mnemonic;

  /// Invoked when the user taps the confirm button. Callers typically
  /// navigate back to `/account` here — [dispose] handles zeroization
  /// regardless, so this callback does not need to.
  final VoidCallback onDone;

  @override
  State<RevealSeedShowPage> createState() => _RevealSeedShowPageState();
}

class _RevealSeedShowPageState extends State<RevealSeedShowPage> {
  @override
  void dispose() {
    widget.mnemonic.zeroize();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SeedShowPage(
      mnemonic: widget.mnemonic,
      onContinue: widget.onDone,
      introText:
          'These are the words you already wrote down when you set up '
          'this wallet. Keep them safe — anyone with this phrase can '
          'access your funds.',
      continueLabel: 'Done',
    );
  }
}
