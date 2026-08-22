/// Reactive iOS screen-capture detection: layers 2-3 of design.md's D11
/// three-layer iOS capture protection. Backed by the native
/// `EventChannel('vault/capture')` registered in `AppDelegate.swift`
/// (`UIScreen.capturedDidChangeNotification` + the initial
/// `UIScreen.main.isCaptured`, and `UIApplication.userDidTakeScreenshotNotification`).
///
/// Android has no native handler for this channel -- `FLAG_SECURE` already
/// blocks the capture outright (see `screen_protection.dart`), so there is
/// nothing to react to. [PlatformScreenCaptureMonitor] degrades to silently
/// empty streams there, and in tests with no mocked handler, mirroring
/// [ScreenProtection]'s existing `MissingPluginException` convention.
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
class PlatformScreenCaptureMonitor implements ScreenCaptureMonitor {
  static const String _name = 'vault/capture';
  static const MethodCodec _codec = StandardMethodCodec();
  static const EventChannel _channel = EventChannel(_name, _codec);

  const PlatformScreenCaptureMonitor();

  @override
  Stream<bool> get isCaptured => _events()
      .where((event) => event['type'] == 'isCaptured')
      .map((event) => event['value'] as bool);

  @override
  Stream<void> get screenshots =>
      _events().where((event) => event['type'] == 'screenshot').map((_) {});

  /// Hand-rolled equivalent of [EventChannel.receiveBroadcastStream] that
  /// catches [MissingPluginException] from the initial `listen` call
  /// ourselves. The stock implementation swallows that exception internally
  /// via `FlutterError.reportError` and leaves the stream open forever
  /// without ever emitting or closing -- correct for a production app, but
  /// untestable with a terminating assertion and noisy in `flutter test`.
  /// Catching it here instead closes the stream deterministically, which is
  /// the same "silently do nothing" outcome from the caller's point of view.
  Stream<Map<Object?, Object?>> _events() {
    late StreamController<Map<Object?, Object?>> controller;
    const methodChannel = MethodChannel(_name, _codec);
    controller = StreamController<Map<Object?, Object?>>.broadcast(
      onListen: () async {
        _channel.binaryMessenger.setMessageHandler(_name, (reply) async {
          if (reply == null) {
            await controller.close();
            return null;
          }
          try {
            final decoded = _codec.decodeEnvelope(reply);
            if (decoded is Map) {
              controller.add(decoded.cast<Object?, Object?>());
            }
          } on PlatformException catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
          return null;
        });
        try {
          await methodChannel.invokeMethod<void>('listen');
        } on MissingPluginException {
          // No native handler for this channel (Android, unmocked tests) --
          // expected, not an error. Degrade to a closed, empty stream.
          await controller.close();
        }
      },
      onCancel: () async {
        _channel.binaryMessenger.setMessageHandler(_name, null);
        try {
          await methodChannel.invokeMethod<void>('cancel');
        } on MissingPluginException {
          // Already gone -- nothing to cancel.
        }
      },
    );
    return controller.stream;
  }
}
