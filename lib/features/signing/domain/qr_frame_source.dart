/// The fakeable boundary over camera QR scanning (design.md's "signing"
/// feature layering: domain `QrFrameSource`, data `MobileScannerFrameSource`)
/// plus [ScanReassembler] — the multi-part BC-UR reassembly/progress logic
/// task 7.4 pairs with it (`qr-air-gapped-signing` spec's "Multi-Part BC-UR
/// Scan And Reassembly" requirement).
library;

import 'package:redoubt/core/ur/ur_api.dart';

/// Emits raw scanned QR payload strings. Implementations own their own
/// camera lifecycle (`start`/`stop`); [QrFrameSource] itself never parses
/// or validates a frame — that's [ScanReassembler]'s job.
abstract interface class QrFrameSource {
  /// Starts scanning and returns a stream of raw decoded QR text, one event
  /// per detected frame (implementations should de-duplicate identical
  /// consecutive frames from a still-visible QR to avoid needless
  /// reassembly work, but [ScanReassembler] tolerates duplicates regardless).
  Stream<String> start();

  /// Stops scanning and releases the camera.
  Future<void> stop();
}

/// Thrown by [ScanReassembler.addFrame] for any scanned frame that cannot
/// be parsed as a UR, disagrees with a previously-seen UR type or fountain
/// framing, or (once complete) fails to decode as a valid
/// `ur:eth-sign-request/...` payload. QR input is attacker-controllable —
/// this boundary never lets a decode problem surface as an uncaught
/// exception type (design.md's "Untrusted-input boundary" testing
/// strategy).
class ScanReassemblyException implements Exception {
  final String message;
  ScanReassemblyException(this.message);

  @override
  String toString() => 'ScanReassemblyException: $message';
}

/// Scan progress: how many distinct frames have been received so far
/// towards [total] (the fountain `seqLen`, or `1` for a single-part scan),
/// and whether reassembly is [isComplete].
class ScanProgress {
  final int received;
  final int total;
  final bool isComplete;

  const ScanProgress({
    required this.received,
    required this.total,
    required this.isComplete,
  });
}

/// Accepts scanned QR frame strings — single-part or animated multi-part
/// BC-UR — in any order, tolerating duplicates, and reassembles them into a
/// decoded [EthSignRequest]. Never attempts to "sign" anything itself; it
/// only decodes. Malformed input never bubbles an uncaught exception type —
/// every failure surfaces as [ScanReassemblyException].
class ScanReassembler {
  String? _urType;
  final FountainDecoder _decoder = FountainDecoder();
  final Set<int> _seenSeqNums = {};
  int? _seqLen;
  EthSignRequest? _result;

  bool get isComplete => _result != null;
  EthSignRequest? get result => _result;

  /// Feeds one scanned [raw] frame. Returns the updated [ScanProgress].
  ///
  /// Throws [ScanReassemblyException] if [raw] cannot be parsed as either a
  /// single-part or multi-part UR, disagrees with a previously-seen UR type
  /// or fountain framing, or — once every fragment has been received —
  /// fails to decode as a valid `eth-sign-request`.
  ScanProgress addFrame(String raw) {
    if (isComplete) {
      final total = _seqLen ?? 1;
      return ScanProgress(received: total, total: total, isComplete: true);
    }

    DecodedUr? single;
    UrDecodeException? singleError;
    try {
      single = decodeSinglePart(raw);
    } on UrDecodeException catch (e) {
      singleError = e;
    }

    if (single != null) {
      return _completeWith(single.type, single.payload, received: 1, total: 1);
    }

    final DecodedMultiPartUr multi;
    try {
      multi = decodeMultiPart(raw);
    } on UrDecodeException {
      throw ScanReassemblyException(
        'not a valid single- or multi-part UR: ${singleError?.message ?? "unrecognized format"}',
      );
    }

    if (_urType != null && _urType != multi.type) {
      throw ScanReassemblyException(
        'inconsistent UR type across scanned frames: expected "$_urType", got "${multi.type}"',
      );
    }
    _urType = multi.type;
    _seqLen = multi.part.seqLen;

    try {
      _decoder.addPart(multi.part);
    } on FountainDecodeException catch (e) {
      throw ScanReassemblyException('fountain reassembly failed: ${e.message}');
    }
    _seenSeqNums.add(multi.part.seqNum);

    if (_decoder.isComplete) {
      return _completeWith(
        multi.type,
        _decoder.message!,
        received: multi.part.seqLen,
        total: multi.part.seqLen,
      );
    }

    return ScanProgress(
      received: _seenSeqNums.length.clamp(0, multi.part.seqLen),
      total: multi.part.seqLen,
      isComplete: false,
    );
  }

  ScanProgress _completeWith(
    String type,
    List<int> payload, {
    required int received,
    required int total,
  }) {
    if (type != 'eth-sign-request') {
      throw ScanReassemblyException(
        'expected an eth-sign-request UR, got "$type"',
      );
    }
    try {
      _result = EthSignRequest.fromCborBytes(payload);
    } on EthSignRequestDecodeException catch (e) {
      throw ScanReassemblyException(
        'invalid eth-sign-request payload: ${e.message}',
      );
    }
    return ScanProgress(received: received, total: total, isComplete: true);
  }
}
