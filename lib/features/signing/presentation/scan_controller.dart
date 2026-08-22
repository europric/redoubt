import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/ur/ur_api.dart';

import '../domain/qr_frame_source.dart';

/// Owns the Scan screen's multi-part BC-UR reassembly (route
/// `/account/scan`, `qr-air-gapped-signing` spec's "Multi-Part BC-UR Scan
/// And Reassembly" requirement).
///
/// Feeds every frame emitted by [frameSource] into [reassembler], in
/// whatever order they arrive, tolerating duplicates. A malformed frame
/// surfaces via [state] as [AsyncError] — it never crashes the scan
/// session, so the user can keep scanning after a misread (the next
/// well-formed frame moves [state] back to [AsyncLoading] or, once
/// reassembly finishes, [AsyncData]).
///
/// `state-management-foundation` Pilot A: [state] replaces the previous
/// hand-rolled `isComplete`/`result`/`error` getters (design.md's "Shared
/// AsyncState Type" requirement). [progress] stays a separately typed
/// field — it is not part of [AsyncState], since it carries
/// feature-specific "N of M parts scanned" data, not generic async
/// lifecycle.
class ScanController extends ChangeNotifier {
  ScanController({required this.frameSource, ScanReassembler? reassembler})
    : reassembler = reassembler ?? ScanReassembler();

  final QrFrameSource frameSource;
  final ScanReassembler reassembler;

  StreamSubscription<String>? _subscription;

  ScanProgress? _progress;
  ScanProgress? get progress => _progress;

  AsyncState<EthSignRequest> _state = const AsyncIdle<EthSignRequest>();
  AsyncState<EthSignRequest> get state => _state;

  final Completer<EthSignRequest> _completed = Completer<EthSignRequest>();

  /// Resolves exactly once, the first time reassembly completes. A
  /// duplicate/late final frame arriving afterward updates [progress]/
  /// [state] as usual but never completes this [Completer] a second time
  /// (that would throw `Bad state: Future already completed`).
  Future<EthSignRequest> get completed => _completed.future;

  void startScanning() {
    _state = const AsyncLoading<EthSignRequest>();
    notifyListeners();
    _subscription = frameSource.start().listen(_onFrame);
  }

  void _onFrame(String raw) {
    try {
      _progress = reassembler.addFrame(raw);
      if (reassembler.isComplete) {
        final result = reassembler.result!;
        _state = AsyncData<EthSignRequest>(result);
        if (!_completed.isCompleted) _completed.complete(result);
      } else {
        _state = const AsyncLoading<EthSignRequest>();
      }
    } on ScanReassemblyException catch (e) {
      _state = AsyncError<EthSignRequest>(e.message);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    frameSource.stop();
    super.dispose();
  }
}
