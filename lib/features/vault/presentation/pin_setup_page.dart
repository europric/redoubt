/// PIN setup screen — `vault-unlock` spec's "PIN Setup With Minimum Numeric
/// Policy" requirement (vault-secure-storage-redesign PR7), redesigned per
/// `critical-screen-ux` spec's "PIN Keypad Input With Dot Indicators" and
/// "PIN Setup Two-Phase Confirm With Unlimited Retry" requirements
/// (ui-redesign PR1, design.md D2/D3): a 6-digit numeric PIN, entered
/// twice to confirm via an on-screen keypad and dot indicators (no OS
/// keyboard), is required before the vault can be committed. Reached from
/// the seed-commit flow (after word verification / phrase import succeeds,
/// before `VaultCommitService.commit` runs — see `app_router.dart`'s
/// `generate.pinSetup`/`import.pinSetup` routes) — never skippable, never
/// biometric-only (`vault-unlock` spec's "No biometric-only bypass exists
/// anywhere" requirement).
///
/// Wrapped in [SecureScreen] like every phrase/PIN-adjacent screen in this
/// codebase.
///
/// **State is a plain `String`, not an OS-text-input controller**
/// (design.md D2): [_digits] holds only the phase currently being entered;
/// deleting the old IME-backed input widget removes the on-screen keyboard
/// entirely, so digits-only / obscured / no-selection hardening is now
/// structural (nothing exists to expose a selection/copy toolbar) instead
/// of flag-configured.
///
/// **Two-phase confirm** (design.md D3): on the 6th digit,
/// `HapticFeedback.lightImpact()` fires immediately; after
/// [kPinRevealDuration] the first phase's digits are stored, the dots
/// clear, and the title retitles to prompt confirmation. A mismatched
/// confirmation shows an error and restarts from the first entry — setup
/// occurs before any vault exists, so `UnlockThrottle` does not apply and
/// retries are unlimited.
///
/// **Accepted residual** (same as `Mnemonic.words`, `design.md`'s own
/// documented caveat): the PIN briefly exists as an immutable Dart `String`
/// before being UTF-8-encoded into a zeroizable `Uint8List` and handed to
/// [onPinConfirmed] — mitigation is lifetime, not erasure, since Dart
/// strings cannot be zero-filled.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redoubt/core/forms/forms.dart';
import 'package:redoubt/core/presentation/presentation.dart';

import 'widgets/numeric_keypad.dart';
import 'widgets/pin_dot_row.dart';

class PinSetupPage extends StatefulWidget {
  const PinSetupPage({super.key, required this.onPinConfirmed});

  /// Invoked with the confirmed 6-digit PIN, UTF-8-encoded. Throwing from
  /// this callback (e.g. `VaultCommitService.commit` failing) is caught and
  /// surfaced as this page's own error text.
  final Future<void> Function(Uint8List pin) onPinConfirmed;

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

enum _SetupPhase { firstEntry, confirm }

class _PinSetupPageState extends State<PinSetupPage> {
  String _digits = '';
  String? _lastDigit;
  String? _firstPin;
  _SetupPhase _phase = _SetupPhase.firstEntry;
  String? _error;
  bool _submitting = false;

  Timer? _advanceTimer;

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }

  void _onDigit(int digit) {
    if (_submitting || _digits.length >= 6) return;
    setState(() {
      _digits += '$digit';
      _lastDigit = '$digit';
      _error = null;
    });
    if (_digits.length == 6) {
      unawaited(HapticFeedback.lightImpact());
      _advanceTimer?.cancel();
      _advanceTimer = Timer(kPinRevealDuration, _onSixthDigitSettled);
    }
  }

  void _onBackspace() {
    if (_submitting || _digits.isEmpty) return;
    setState(() {
      _digits = _digits.substring(0, _digits.length - 1);
      _lastDigit = null;
    });
  }

  void _onSixthDigitSettled() {
    if (!mounted) return;

    if (_phase == _SetupPhase.firstEntry) {
      setState(() {
        _firstPin = _digits;
        _digits = '';
        _lastDigit = null;
        _phase = _SetupPhase.confirm;
      });
      return;
    }

    final matches = PinInput(_firstPin!).matches(PinInput(_digits));
    if (matches) {
      unawaited(_submit());
    } else {
      setState(() {
        _error = PinInput.mismatchMessage;
        _digits = '';
        _lastDigit = null;
        _firstPin = null;
        _phase = _SetupPhase.firstEntry;
      });
    }
  }

  Future<void> _submit() async {
    final confirmedPin = PinInput(_firstPin!);
    setState(() => _submitting = true);
    try {
      await widget.onPinConfirmed(Uint8List.fromList(confirmedPin.toBytes()));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not set up your PIN. Please try again.';
        _digits = '';
        _lastDigit = null;
        _firstPin = null;
        _phase = _SetupPhase.firstEntry;
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _phase == _SetupPhase.firstEntry
        ? 'Configura tu pin'
        : 'Repite el pin';

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        // The dots stay pinned near the top and the keypad stays pinned to
        // the bottom, inside the `SafeArea`. `ConstrainedBox(minHeight:...)`
        // inside a `SingleChildScrollView`, with the outer `Column` using
        // `MainAxisAlignment.spaceBetween`, is the standard "sticky footer
        // in a scroll view" idiom: when the two children's natural height is
        // less than the viewport, the leftover space is inserted between
        // them, pushing the keypad to the bottom edge; when it isn't (a
        // short viewport), the column simply grows past `minHeight` to its
        // natural size and the scroll view takes over -- no intrinsic-size
        // computation is involved anywhere, so it does not matter that
        // `NumericKeypad`'s grid is shrink-wrapped.
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const verticalPadding = 32.0;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - verticalPadding,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 24),
                          PinDotRow(
                            filledCount: _digits.length,
                            revealChar: _lastDigit,
                          ),
                          // Committing the PIN runs real Argon2id/AEAD work,
                          // which is not instant -- without this, a disabled
                          // keypad with no other feedback reads as a frozen
                          // app rather than work in progress.
                          if (_submitting)
                            const Padding(
                              padding: EdgeInsets.only(top: 20),
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              ),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: NumericKeypad(
                          onDigit: _onDigit,
                          onBackspace: _onBackspace,
                          enabled: !_submitting,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
