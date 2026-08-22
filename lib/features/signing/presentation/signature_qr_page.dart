import 'dart:async';

import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';

import '../domain/signed_result.dart';
import 'signature_qr.dart';

/// The Signature screen (route `/account/signature`) — the final step of
/// the offline signing flow.
///
/// `qr-air-gapped-signing` spec's "Offline Sign And BC-UR Signature Output"
/// requirement: renders the `eth-signature` UR as a QR, single or animated
/// multi-part depending on payload size (see [buildSignatureQrFrames]).
/// This widget only ever holds a [SignedResult] — no private key reference
/// exists anywhere in this file (see `signature_qr.dart`'s own structural
/// guarantee doc comment), so there is nothing key-shaped to retain after
/// rendering.
///
/// Wrapped in [SecureScreen] per design.md's "SecureScreen wraps the
/// phrase, review and signature pages".
///
/// **Terminal screen, both exits collapse to `/account`** (design.md D6,
/// `qr-air-gapped-signing` spec's "Signature Screen Is Terminal — No Back
/// Navigation" requirement): this widget never navigates itself -- it only
/// ever invokes the injected [onDone], both from [confirmScannedButton] and
/// from an intercepted hardware/gesture back (see [PopScope] in [build]).
/// The composition root ([AppRouter]'s `signature` route) supplies
/// `onDone: () => context.goNamed('account')`. `onDone == null` keeps the
/// default pop behavior so this page is never a dead end.
class SignatureQrPage extends StatefulWidget {
  const SignatureQrPage({
    super.key,
    required this.signedResult,
    this.maxFragmentLength = defaultMaxSignatureFragmentLength,
    this.frameInterval = const Duration(seconds: 1),
    this.onDone,
  });

  final SignedResult signedResult;
  final int maxFragmentLength;
  final Duration frameInterval;

  /// Invoked by BOTH the confirm button and an intercepted hardware/gesture
  /// back (design.md D6). `null` keeps the default `PopScope`/back
  /// behavior instead of intercepting it.
  final VoidCallback? onDone;

  @override
  State<SignatureQrPage> createState() => _SignatureQrPageState();
}

class _SignatureQrPageState extends State<SignatureQrPage> {
  late final List<String> _frames = buildSignatureQrFrames(
    widget.signedResult,
    maxFragmentLength: widget.maxFragmentLength,
  );
  int _frameIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_frames.length > 1) {
      _timer = Timer.periodic(widget.frameInterval, (_) {
        setState(() => _frameIndex = (_frameIndex + 1) % _frames.length);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onDone = widget.onDone;
    return SecureScreen(
      // Amended D6: the hardware/gesture back is intercepted and
      // redirected to the SAME `onDone` the confirm button calls, so both
      // exits land on `/account` in one hop. `canPop: onDone == null` keeps
      // the default pop when no callback is wired (page is never a dead
      // end) -- same established pattern as `recovery_page.dart`.
      child: PopScope(
        canPop: onDone == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onDone!();
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Signature'),
            automaticallyImplyLeading: false,
          ),
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QrCodeView(
                          qrKey: const Key('signatureQr'),
                          data: _frames[_frameIndex],
                          size: 260,
                        ),
                        if (_frames.length > 1)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Part ${_frameIndex + 1} of ${_frames.length}',
                            ),
                          ),
                        const SizedBox(height: 16),
                        const Text(
                          'Scan this with MetaMask Extension to complete '
                          'signing.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          key: const Key('confirmScannedButton'),
                          onPressed: onDone,
                          child: const Text("I've scanned it"),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
