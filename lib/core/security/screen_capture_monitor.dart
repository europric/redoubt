/// Reactive iOS screen-capture detection: layers 2-3 of design.md's D11
/// three-layer iOS capture protection. Backed by the native
/// `EventChannel('vault/capture')` registered in `AppDelegate.swift`
/// (`UIScreen.capturedDidChangeNotification` + the initial
/// `UIScreen.main.isCaptured`, and `UIApplication.userDidTakeScreenshotNotification`).
///
/// **Shared-session architecture**: [PlatformScreenCaptureMonitor] multiplexes
/// all concurrent [isCaptured] and [screenshots] subscriptions over one shared,
/// refcounted native listen/cancel session per process. An internal
/// `_CaptureSession` singleton owns the single `EventChannel` registration, a
/// broadcast event controller, and a serialized async queue for native
/// listen/cancel operations. This prevents the crash caused by a
/// `PlatformException("No active stream to cancel")` when two `SecureScreen`
/// widgets mount/unmount concurrently, and ensures both streams receive events
/// without one subscription's handler overwriting the other's.
///
/// Android has no native handler for this channel -- `FLAG_SECURE` already
/// blocks the capture outright (see `screen_protection.dart`), so there is
/// nothing to react to. [PlatformScreenCaptureMonitor] degrades to silently
/// empty streams there, closing permanently after the first
/// [MissingPluginException] (never retrying native `listen` on later mounts).
///
/// **Decision-gate outcome (design.md D11 / tasks.md Phase 5.2)**: the
/// primary layer-1 blocking technique (secure-overlay window reparenting via
/// `ScreenCaptureProtection.swift`) could not be verified in this apply run
/// -- no physical iOS device was available, and this codebase's own design
/// doc states Simulator cannot exercise the CAMetalLayer-reparenting
/// question layer 1 exists to answer. Per the decision gate's required
/// conservative fallback, layer 1 was NOT wired into production this PR;
/// only these reactive layers 2-3 ship. See
/// `specs/seed-exposure-protection/spec.md`'s resulting reduced-guarantee
/// wording -- iOS has best-available blocking (still just the existing
/// background/app-switcher obscuring) plus this reactive detection, not a
/// `FLAG_SECURE`-equivalent guarantee.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reactive iOS screen-capture signals. See library doc comment for the
/// current (reduced) guarantee this provides.
abstract interface class ScreenCaptureMonitor {
  /// Emits the current recording/mirroring state whenever it changes
  /// (`UIScreen.isCaptured`), including the initial value on subscribe.
  Stream<bool> get isCaptured;

  /// Emits once each time the user takes a screenshot of the app.
  Stream<void> get screenshots;
}

/// [EventChannel]-backed adapter over `vault/capture`.
///
/// All subscriptions share one internal [PlatformScreenCaptureMonitor._CaptureSession]
/// session. See library doc comment for details.
class PlatformScreenCaptureMonitor implements ScreenCaptureMonitor {
  const PlatformScreenCaptureMonitor();

  @override
  Stream<bool> get isCaptured => Stream<bool>.multi((out) {
        final session = _CaptureSession.instance;
        final source = session.acquire();
        var released = false;

        void release() {
          if (!released) {
            released = true;
            session.release();
          }
        }

        // Replay cached isCaptured value immediately, if one exists.
        final cached = session.lastIsCaptured;
        if (cached != null) {
          out.add(cached);
        }

        final sub = source
            .where((e) => e['type'] == 'isCaptured')
            .map((e) => e['value']! as bool)
            .listen(
              out.add,
              onError: out.addError,
              onDone: () {
                release();
                out.close();
              },
            );

        out.onCancel = () {
          release();
          return sub.cancel();
        };
      });

  @override
  Stream<void> get screenshots => Stream<void>.multi((out) {
        final session = _CaptureSession.instance;
        final source = session.acquire();
        var released = false;

        void release() {
          if (!released) {
            released = true;
            session.release();
          }
        }

        session.registerScreenshotSink(out);

        // Screenshot-typed events are dispatched directly to the
        // single-owner slot (see [_CaptureSession._dispatchScreenshot]), not
        // forwarded through this subscription — only onError/onDone
        // propagation is needed from `source` here.
        final sub = source.listen(
          (_) {},
          onError: out.addError,
          onDone: () {
            session.unregisterScreenshotSink(out);
            release();
            out.close();
          },
        );

        out.onCancel = () {
          session.unregisterScreenshotSink(out);
          release();
          return sub.cancel();
        };
      });

  /// Resets the shared [_CaptureSession] singleton. For test isolation only.
  @visibleForTesting
  static void debugReset() => _CaptureSession.debugReset();

  /// Overrides the clock used to arm/evaluate the screenshot-warning
  /// handoff TTL. For deterministic tests only; restored by [debugReset].
  @visibleForTesting
  static set debugNow(DateTime Function() now) => _CaptureSession.debugNow = now;
}

/// Process-level singleton that owns the single [EventChannel] registration,
/// one [StreamController.broadcast] of decoded native events, a subscriber
/// refcount, the last-known `isCaptured` value, an Android terminal latch,
/// and a serialized async queue guaranteeing ordered native listen/cancel.
///
/// Multiple [Stream.multi] views ([isCaptured], [screenshots]) each call
/// [acquire] on subscription and [release] on unsubscribe, sharing one native
/// session as long as any subscriber is active.
class _CaptureSession {
  _CaptureSession._();

  /// The process-wide singleton. Used by [PlatformScreenCaptureMonitor]'s
  /// [Stream.multi] views.
  static final _CaptureSession instance = _CaptureSession._();

  // --- State ---

  int _refs = 0;
  bool _open = false;

  /// Set by [_openIfNeeded] when [MissingPluginException] is caught. Once set,
  /// no further native listen attempts occur for the process lifetime.
  bool _terminal = false;

  /// Cached last-known isCaptured value, for late-subscriber replay.
  /// Updated in the message handler BEFORE the event is dispatched.
  bool? _lastIsCaptured;

  /// Exposed for replay in [Stream.multi] views.
  bool? get lastIsCaptured => _lastIsCaptured;

  /// How long an unowned (or owner-less, post-transfer-search) screenshot
  /// warning may still be delivered to a newly (re)subscribing sink.
  static const Duration screenshotHandoffWindow = Duration(seconds: 2);

  /// Clock used to arm/evaluate [screenshotHandoffWindow]. Overridable via
  /// [PlatformScreenCaptureMonitor.debugNow] for deterministic tests —
  /// deliberately not a [Timer], so the TTL cannot be skewed by
  /// [WidgetTester.runAsync] or a FakeAsync zone.
  @visibleForTesting
  static DateTime Function() debugNow = DateTime.now;

  /// Live `screenshots` sinks, in subscription order (newest last).
  final List<MultiStreamController<void>> _screenshotSinks = [];

  /// When the current warning was armed, or `null` if none is pending.
  DateTime? _pendingScreenshotAt;

  /// The sink currently holding the pending warning, or `null` if unowned.
  MultiStreamController<void>? _screenshotOwner;

  /// Sinks that have already received the current warning — guarantees no
  /// sink is ever offered the same warning twice.
  final Set<MultiStreamController<void>> _screenshotSeenBy = {};

  /// The single broadcast controller for decoded native events.
  StreamController<Map<Object?, Object?>>? _controller;

  /// Serialized async queue: every native operation is a link in this
  /// [Future] chain, so overlapping [acquire]/[release] calls never race.
  Future<void> _queue = Future<void>.value();

  // --- Channels ---

  final MethodChannel _method = const MethodChannel(_name, _codec);
  static const String _name = 'vault/capture';
  static const MethodCodec _codec = StandardMethodCodec();
  static const EventChannel _channel = EventChannel(_name, _codec);

  // --- Public API for Stream.multi views ---

  /// Adds one reference and returns the shared broadcast stream.
  /// Defers [_openIfNeeded] via the serialized queue when the session is not
  /// yet open.
  ///
  /// When the session is terminal ([MissingPluginException] already caught),
  /// returns an immediately-done stream without creating a controller.
  Stream<Map<Object?, Object?>> acquire() {
    _refs++;
    if (_terminal) {
      return const Stream<Map<Object?, Object?>>.empty();
    }
    final c = _controller ??= StreamController<Map<Object?, Object?>>.broadcast();
    _enqueue(_openIfNeeded);
    return c.stream;
  }

  /// Removes one reference. Defers [_teardownIfIdle] via the serialized queue
  /// when the refcount reaches zero.
  ///
  /// **Idempotent**: safe to call multiple times per listener (e.g. when both
  /// `onDone` and `onCancel` fire).
  void release() {
    if (_refs > 0) _refs--;
    _enqueue(_teardownIfIdle);
  }

  // --- Queue ---

  /// Appends [step] to the serialized queue. Each step re-reads mutable state
  /// at execution time, so a churn from 1→0→1 collapses into a no-op.
  void _enqueue(Future<void> Function() step) {
    _queue = _queue.then((_) => step());
  }

  // --- Native listen ---

  /// Registers the message handler on the [EventChannel]'s binary messenger
  /// and invokes native `listen`, unless already open or terminal.
  Future<void> _openIfNeeded() async {
    if (_open || _terminal) return;

    _open = true;
    _channel.binaryMessenger.setMessageHandler(_name, _handleNativeEvent);

    try {
      await _method.invokeMethod<void>('listen');
    } on MissingPluginException {
      // No native handler (Android, unmocked test) — terminal, never retry.
      _terminal = true;
      _channel.binaryMessenger.setMessageHandler(_name, null);
      final c = _controller;
      _controller = null; // prevent double-close from _teardownIfIdle
      await c?.close();
    }
  }

  /// Decodes a native envelope and dispatches to the broadcast controller.
  /// Updates [_lastIsCaptured] before dispatching so late‑subscriber replay
  /// sees the latest value.
  Future<ByteData?> _handleNativeEvent(ByteData? reply) async {
    if (reply == null) {
      await _controller?.close();
      return null;
    }
    try {
      final decoded = _codec.decodeEnvelope(reply);
      if (decoded is Map) {
        final typed = decoded.cast<Object?, Object?>();
        // Cache isCaptured value before dispatching.
        if (typed['type'] == 'isCaptured') {
          _lastIsCaptured = typed['value'] as bool?;
        } else if (typed['type'] == 'screenshot') {
          _dispatchScreenshot();
        }
        _controller?.add(typed);
      }
    } on PlatformException catch (error, stackTrace) {
      _controller?.addError(error, stackTrace);
    }
    return null;
  }

  // --- Native cancel ---

  /// Tears down when refcount is zero: clears the message handler, invokes
  /// native `cancel`, clears the cached value, and closes the controller.
  /// [PlatformException] from cancel is silently swallowed (unactionable with
  /// no subscriber left).
  ///
  /// **Deliberately does NOT clear the screenshot-warning slot** (unlike
  /// [_lastIsCaptured], which it does clear). The slot's whole purpose is to
  /// survive exactly this sequence: last sink cancels -> teardown queued ->
  /// next screen subscribes within [screenshotHandoffWindow]. A future
  /// reader "fixing" this back to match the [_lastIsCaptured] pattern would
  /// silently reintroduce the lost-warning defect this class exists to fix.
  Future<void> _teardownIfIdle() async {
    if (_refs > 0 || !_open) return;

    final c = _controller;
    _controller = null;
    _open = false;
    _channel.binaryMessenger.setMessageHandler(_name, null);

    try {
      await _method.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Already gone — nothing to cancel.
    } on PlatformException {
      // "No active stream to cancel" from concurrent churn is benign.
    }

    _lastIsCaptured = null;
    await c?.close();
  }

  // --- Screenshot single-owner warning slot ---

  /// Arms a new warning and offers it to the newest live sink, if any.
  /// Clears [_screenshotSeenBy] — a new native event is a new warning, not a
  /// repeat of a previous one.
  void _dispatchScreenshot() {
    _pendingScreenshotAt = debugNow();
    _screenshotSeenBy.clear();
    if (_screenshotSinks.isNotEmpty) {
      _offerTo(_screenshotSinks.last);
    }
  }

  /// Registers a new live `screenshots` sink. If a warning is armed, within
  /// [screenshotHandoffWindow], unowned, and not already seen by this sink,
  /// offers it immediately.
  void registerScreenshotSink(MultiStreamController<void> out) {
    _screenshotSinks.add(out);
    if (_pendingScreenshotAt != null &&
        _withinHandoffWindow() &&
        _screenshotOwner == null &&
        !_screenshotSeenBy.contains(out)) {
      _offerTo(out);
    }
  }

  /// Unregisters a `screenshots` sink. If it was the owner, ownership
  /// transfers to the newest remaining unseen sink, provided the warning is
  /// still armed and within the TTL; otherwise the warning is left unowned
  /// for the next subscriber.
  void unregisterScreenshotSink(MultiStreamController<void> out) {
    _screenshotSinks.remove(out);
    if (!identical(_screenshotOwner, out)) return;

    _screenshotOwner = null;
    if (_pendingScreenshotAt == null || !_withinHandoffWindow()) return;

    for (var i = _screenshotSinks.length - 1; i >= 0; i--) {
      final candidate = _screenshotSinks[i];
      if (!_screenshotSeenBy.contains(candidate)) {
        _offerTo(candidate);
        return;
      }
    }
  }

  bool _withinHandoffWindow() {
    final at = _pendingScreenshotAt;
    return at != null && debugNow().difference(at) <= screenshotHandoffWindow;
  }

  void _offerTo(MultiStreamController<void> sink) {
    _screenshotOwner = sink;
    _screenshotSeenBy.add(sink);
    sink.add(null);
  }

  // --- Test isolation ---

  @visibleForTesting
  static void debugReset() {
    final s = instance;
    s._refs = 0;
    s._queue = Future<void>.value();
    s._open = false;
    s._terminal = false;
    s._lastIsCaptured = null;
    s._controller = null;
    s._screenshotSinks.clear();
    s._pendingScreenshotAt = null;
    s._screenshotOwner = null;
    s._screenshotSeenBy.clear();
    debugNow = DateTime.now;
    _channel.binaryMessenger.setMessageHandler(_name, null);
  }
}