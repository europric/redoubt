import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// First method/event channels ever registered here (design.md D11).
  ///
  /// `vault/screen` (layer 1, the community secure-overlay technique) is
  /// deliberately NOT registered on iOS: tasks.md Phase 5.2's decision gate
  /// could not verify it in this apply run (no physical device; Simulator
  /// cannot exercise the CAMetalLayer-reparenting question it exists to
  /// answer -- see `ScreenCaptureProtection.swift`'s header comment for the
  /// full record). `ScreenProtection._invoke` on the Dart side already
  /// treats a missing handler for this channel as a safe, expected no-op on
  /// iOS, so this is a documented no-op, not a regression.
  ///
  /// `vault/capture` (layers 2-3, reactive detection) DOES ship regardless
  /// of that outcome -- both are documented, always-available UIKit APIs
  /// with no rendering risk.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VaultCaptureChannel")
    else { return }
    let messenger = registrar.messenger()

    let captureChannel = FlutterEventChannel(name: "vault/capture", binaryMessenger: messenger)
    captureChannel.setStreamHandler(ScreenCaptureStreamHandler())
  }
}

/// Backs `lib/core/security/screen_capture_monitor.dart`'s
/// `PlatformScreenCaptureMonitor`. Emits a tagged event union:
///   `{"type": "isCaptured", "value": Bool}` -- `UIScreen.isCaptured`
///     changed (active recording/mirroring), including the initial value
///     the moment a listener attaches.
///   `{"type": "screenshot"}` -- the user just took a screenshot.
///
/// Always observing once a listener attaches -- independent of the
/// `vault/screen` layer-1 outcome above, per design.md D11.
private final class ScreenCaptureStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleCapturedDidChange),
      name: UIScreen.capturedDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleScreenshot),
      name: UIApplication.userDidTakeScreenshotNotification, object: nil)

    // The initial state, per design.md D11 ("plus the initial
    // UIScreen.main.isCaptured").
    events(["type": "isCaptured", "value": UIScreen.main.isCaptured])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    eventSink = nil
    return nil
  }

  @objc private func handleCapturedDidChange() {
    eventSink?(["type": "isCaptured", "value": UIScreen.main.isCaptured])
  }

  @objc private func handleScreenshot() {
    eventSink?(["type": "screenshot"])
  }
}
