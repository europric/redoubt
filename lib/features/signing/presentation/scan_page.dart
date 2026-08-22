import 'package:flutter/material.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/ur/ur_api.dart';

import 'scan_controller.dart';

/// The Scan screen (route `/account/scan`).
///
/// `qr-air-gapped-signing` spec's "Multi-Part BC-UR Scan And Reassembly"
/// requirement: accepts fragments in any scan order, shows progress for a
/// partial scan, and never attempts to sign until reassembly is complete
/// (that only happens once, wired in [ControllerHost.onAttach] via
/// [ScanController.completed]).
///
/// Wrapped in [SecureScreen] — scanning happens immediately before signing,
/// so this screen is treated as sensitive even though it doesn't itself
/// display key material (design.md's "SecureScreen wraps the phrase,
/// review and signature pages" — scan is grouped with review/signature as
/// part of the same sensitive signing flow).
///
/// `state-management-foundation` Pilot A: this page is now a
/// `StatelessWidget` wrapped in `ControllerHost<ScanController>`, which
/// CREATES and owns the controller from [createController] (invoked
/// exactly once) instead of taking an already-constructed `controller`
/// instance — see design.md's "The /account/scan builder passes factories,
/// not live instances" decision, which fixes a camera-handle leak /
/// silent-scanning-stops-working bug that existed on a router-triggered
/// rebuild.
///
/// This page has zero direct dependency on `mobile_scanner` — the actual
/// camera preview widget is supplied by the caller via
/// [cameraPreviewBuilder] (the composition root wires the real
/// `MobileScanner` widget bound to the created `ScanController`'s frame
/// source; tests and any camera-less fallback simply omit it), keeping
/// this file's own logic fakeable/testable through [ScanController] +
/// `QrFrameSource` alone.
class ScanPage extends StatelessWidget {
  const ScanPage({
    super.key,
    required this.createController,
    required this.onComplete,
    this.cameraPreviewBuilder,
  });

  /// Invoked exactly once (by [ControllerHost]) to construct this page's
  /// [ScanController].
  final ScanController Function() createController;

  final ValueChanged<EthSignRequest> onComplete;

  /// Builds the camera preview widget from the controller this page
  /// created, so both the preview and the controller share the same
  /// underlying frame source instance.
  final Widget Function(ScanController controller)? cameraPreviewBuilder;

  @override
  Widget build(BuildContext context) {
    return ControllerHost<ScanController>(
      create: createController,
      onAttach: (context, controller) {
        controller.startScanning();
        // One-shot: wired here (initState-equivalent), never in `builder`,
        // so a rebuild never re-registers this continuation and
        // `onComplete` cannot fire more than once.
        controller.completed.then((request) {
          if (context.mounted) onComplete(request);
        });
      },
      builder: (context, controller) => _ScanPageBody(
        controller: controller,
        cameraPreview: cameraPreviewBuilder?.call(controller),
      ),
    );
  }
}

class _ScanPageBody extends StatelessWidget {
  const _ScanPageBody({required this.controller, this.cameraPreview});

  final ScanController controller;
  final Widget? cameraPreview;

  @override
  Widget build(BuildContext context) {
    final progress = controller.progress;
    final errorMessage = controller.state.errorOrNull;

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: const Text('Scan to Sign')),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    // A capped max width keeps the square viewfinder from
                    // overflowing the available vertical space on short/
                    // landscape viewports; on typical portrait phone
                    // screens this simply centers a fixed-size square.
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: _SquareViewfinder(cameraPreview: cameraPreview),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (progress != null && !progress.isComplete)
                      Text(
                        'Scanned ${progress.received} of ${progress.total} parts',
                        textAlign: TextAlign.center,
                      )
                    else if (progress == null)
                      const Text(
                        'Point the camera at MetaMask Extension\'s QR code',
                        textAlign: TextAlign.center,
                      ),
                    if (errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          errorMessage,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // D7: the Expanded spacer moves BELOW the instruction text so
              // the fixed-aspect-ratio viewfinder above stays top-aligned
              // instead of being stretched/centered to fill the screen.
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bounds [cameraPreview] (or a camera-less fallback, when null) inside a
/// square viewfinder with 4 corner brackets — `critical-screen-ux` spec's
/// "Scan Square Viewfinder" requirement / design.md D7. The fallback shares
/// the exact same [AspectRatio] bounds as the real preview would, so the
/// two states are structurally identical in size.
///
/// Purely presentational: no dependency on `mobile_scanner` or
/// `QrFrameSource` — [mobile_scanner_frame_source.dart] is not opened by
/// this change.
class _SquareViewfinder extends StatelessWidget {
  const _SquareViewfinder({this.cameraPreview});

  final Widget? cameraPreview;

  // `brand-theme` spec's "Theme-Independent Presentation Exceptions"
  // requirement (design.md's documented exception): this overlay paints
  // over a live camera feed, where legibility must not depend on a surface
  // token. `Colors.black`/`Colors.white70` here and `Colors.white` in
  // [_CornerBracketPainter] below STAY hardcoded literals, deliberately NOT
  // sourced from `Theme.of(context)`/`ColorScheme` — do not "fix" this.
  static const _fallback = ColoredBox(
    color: Colors.black,
    child: Center(
      child: Icon(Icons.qr_code_scanner, color: Colors.white70, size: 64),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // A zero-radius ClipRRect IS a ClipRect (brand-theme's flat-geometry
    // requirement, design.md D8) — the corner brackets below still convey
    // "square viewfinder" per critical-screen-ux's "Scan Square Viewfinder"
    // requirement, which constrains bounds + corner brackets only.
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            cameraPreview ?? _fallback,
            for (var i = 0; i < 4; i++) _ViewfinderCorner(index: i),
          ],
        ),
      ),
    );
  }
}

/// One of the 4 corner brackets drawn over the square viewfinder.
/// `index` 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right.
class _ViewfinderCorner extends StatelessWidget {
  const _ViewfinderCorner({required this.index});

  final int index;

  static const _size = 28.0;
  static const _inset = 12.0;
  static const _thickness = 3.0;

  bool get _isTop => index < 2;
  bool get _isLeft => index.isEven;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      key: Key('scan-viewfinder-corner-$index'),
      top: _isTop ? _inset : null,
      bottom: _isTop ? null : _inset,
      left: _isLeft ? _inset : null,
      right: _isLeft ? null : _inset,
      child: SizedBox(
        width: _size,
        height: _size,
        child: CustomPaint(
          painter: _CornerBracketPainter(
            isTop: _isTop,
            isLeft: _isLeft,
            thickness: _thickness,
          ),
        ),
      ),
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  const _CornerBracketPainter({
    required this.isTop,
    required this.isLeft,
    required this.thickness,
  });

  final bool isTop;
  final bool isLeft;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final x = isLeft ? 0.0 : size.width;
    final y = isTop ? 0.0 : size.height;

    canvas
      ..drawLine(Offset(x, 0), Offset(x, size.height), paint)
      ..drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(covariant _CornerBracketPainter oldDelegate) =>
      oldDelegate.isTop != isTop ||
      oldDelegate.isLeft != isLeft ||
      oldDelegate.thickness != thickness;
}
