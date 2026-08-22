/// PIN entry screen — collects the PIN for signing (route `/account/sign/pin`,
/// vault-secure-storage-redesign PR7). `vault-unlock` spec's "Exponential
/// Backoff On Failed Attempts, Never Auto-Wipe" requirement, UI side: the
/// keypad stays disabled with a live countdown while
/// [UnlockThrottle.remainingDelay] is nonzero, and enables the instant it
/// reaches zero — this page polls [unlockThrottle] every second while
/// mounted so the countdown reflects real elapsed time without requiring
/// the caller to drive it.
///
/// Redesigned per `critical-screen-ux` spec's "PIN Keypad Input With Dot
/// Indicators" requirement (ui-redesign PR1, design.md D2/D3): an on-screen
/// keypad and dot indicators replace the OS-keyboard text input, and the
/// 6th digit auto-submits — the reference is a lock screen, so no separate
/// "Unlock" button is shown.
///
/// Wrapped in [SecureScreen] like every phrase/PIN-adjacent screen in this
/// codebase. Same field-hardening posture as `pin_setup_page.dart` (no
/// autocorrect/suggestions/interactive-selection) is now structural — there
/// is no OS-text-input widget at all, only the keypad — see that file's doc
/// comment for the full rationale.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redoubt/core/forms/forms.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

import 'widgets/numeric_keypad.dart';
import 'widgets/pin_dot_row.dart';

/// Thrown by an [PinEntryPage.onSubmit] callback to surface a specific,
/// user-facing error message on this page (e.g. a caught `WrongPinFailure`
/// re-raised with its message) without exposing the underlying vault
/// exception type to this widget.
class PinRejectedFailure implements Exception {
  const PinRejectedFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class PinEntryPage extends StatefulWidget {
  const PinEntryPage({
    super.key,
    required this.unlockThrottle,
    required this.onSubmit,
    this.errorText,
    this.onBiometricRetry,
    this.biometricKind = BiometricKind.none,
  });

  final UnlockThrottle unlockThrottle;

  /// Invoked with the entered PIN, UTF-8-encoded, once the 6th digit is
  /// entered while enabled. Throw [PinRejectedFailure] (or any other
  /// object) to surface an error on this page and allow a retry.
  final Future<void> Function(Uint8List pin) onSubmit;

  /// An error to show immediately on first build (e.g. a prior attempt's
  /// `WrongPinFailure` message, if this page is rebuilt after a retry).
  final String? errorText;

  /// Optional retry-biometric passthrough to [NumericKeypad]'s own optional
  /// biometric key (biometric-unlock-onboarding design.md D7,
  /// `critical-screen-ux` spec delta's "Biometric retry icon appears only
  /// on the app-unlock screen" requirement). `null` (the default) keeps
  /// every pre-existing call site (sign/reveal/delete/PIN-setup) unaffected
  /// structurally -- only `AppUnlockPage` ever passes this.
  final VoidCallback? onBiometricRetry;

  /// The modality to represent for [onBiometricRetry]'s icon. Ignored when
  /// [onBiometricRetry] is `null`.
  final BiometricKind biometricKind;

  @override
  State<PinEntryPage> createState() => _PinEntryPageState();
}

class _PinEntryPageState extends State<PinEntryPage> {
  String _digits = '';
  String? _lastDigit;
  Timer? _pollTimer;
  Timer? _advanceTimer;

  Duration _remaining = Duration.zero;
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _error = widget.errorText;
    unawaited(_refreshRemaining());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshRemaining()),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _advanceTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshRemaining() async {
    final remaining = await widget.unlockThrottle.remainingDelay();
    if (!mounted) return;
    setState(() => _remaining = remaining);
  }

  bool get _keypadEnabled => !_submitting && _remaining <= Duration.zero;

  void _onDigit(int digit) {
    if (!_keypadEnabled || _digits.length >= 6) return;
    setState(() {
      _digits += '$digit';
      _lastDigit = '$digit';
      _error = null;
    });
    if (_digits.length == 6) {
      unawaited(HapticFeedback.lightImpact());
      _advanceTimer?.cancel();
      _advanceTimer = Timer(kPinRevealDuration, () => unawaited(_submit()));
    }
  }

  void _onBackspace() {
    if (!_keypadEnabled || _digits.isEmpty) return;
    setState(() {
      _digits = _digits.substring(0, _digits.length - 1);
      _lastDigit = null;
    });
  }

  Future<void> _submit() async {
    if (!mounted) return;
    final pin = PinInput(_digits);
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(Uint8List.fromList(pin.toBytes()));
      if (mounted) {
        setState(() {
          _digits = '';
          _lastDigit = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _digits = '';
        _lastDigit = null;
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
      await _refreshRemaining();
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _remaining > Duration.zero;

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Enter Your PIN')),
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
                          // Unlocking the vault runs real Argon2id/AEAD work,
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
                          if (waiting)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                'Too many attempts. Try again in '
                                '${_remaining.inSeconds}s.',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
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
                          enabled: _keypadEnabled,
                          onBiometric: widget.onBiometricRetry,
                          biometricIcon: switch (widget.biometricKind) {
                            BiometricKind.face => Icons.face,
                            BiometricKind.iris => Icons.remove_red_eye,
                            BiometricKind.fingerprint ||
                            BiometricKind.none => Icons.fingerprint,
                          },
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
