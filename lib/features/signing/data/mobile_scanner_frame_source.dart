/// [QrFrameSource] backed by `mobile_scanner` (design.md's pinned
/// `^7.0.0`). One of design.md's "hardest to isolate" plugin boundaries
/// (camera) — this class is intentionally thin so almost all of the
/// signing feature's real logic ([ScanReassembler], [EthTransactionSigner])
/// stays testable without a device/camera; only this adapter itself is
/// unverified without a physical device or emulator with a camera (see
/// this PR's manual-device checklist).
///
/// **`autoStart: false` is load-bearing**: the `MobileScanner` widget calls
/// `controller.start()` itself whenever `controller.autoStart` is true
/// (mobile_scanner's own default), racing against this class's own explicit
/// [start] call below. Losing that race throws
/// `MobileScannerException(controllerInitializing, ...)` — observed on iOS,
/// where the native camera takes long enough to initialize for the second
/// `start()` call to land while the first is still in flight. Disabling
/// `autoStart` makes this class the sole owner of the controller's
/// start/stop lifecycle, matching [stop]'s existing explicit
/// stop-then-dispose.
library;

import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/qr_frame_source.dart';

class MobileScannerFrameSource implements QrFrameSource {
  MobileScannerFrameSource({MobileScannerController? controller})
    : _controller = controller ?? MobileScannerController(autoStart: false);

  final MobileScannerController _controller;

  /// Exposed so [ScanPage] can attach the camera preview widget to the
  /// same controller instance this frame source drives.
  MobileScannerController get controller => _controller;

  @override
  Stream<String> start() {
    // `unawaited` is intentionally not used here — errors starting the
    // camera surface through the returned stream via the controller's own
    // error propagation, not a fire-and-forget future.
    _controller.start();
    return _controller.barcodes
        .expand((capture) => capture.barcodes)
        .map((barcode) => barcode.rawValue)
        .where((value) => value != null)
        .cast<String>();
  }

  @override
  Future<void> stop() async {
    await _controller.stop();
    await _controller.dispose();
  }
}

/// Builds the camera preview widget for [source] (design.md D8). Takes the
/// domain-level [QrFrameSource] rather than a concrete [MobileScannerController]
/// so the composition root (`app_router.dart`) never needs to import
/// `mobile_scanner` itself just to wire the preview — this file is already
/// the sole designated gateway for that package (R5). An unrecognized
/// [QrFrameSource] implementation degrades to an empty preview instead of
/// throwing, matching the previous inline `switch` this replaces.
Widget buildMobileScannerPreview(QrFrameSource source) {
  return switch (source) {
    MobileScannerFrameSource(:final controller) =>
      MobileScanner(controller: controller),
    _ => const SizedBox.shrink(),
  };
}
