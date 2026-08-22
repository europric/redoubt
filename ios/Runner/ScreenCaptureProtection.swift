// CONFIRMED BROKEN ON A PHYSICAL DEVICE. NOT WIRED INTO THE RUNNER TARGET.
//
// ============================================================================
// VERIFICATION RESULT (follow-up to ios-android-platform-parity-fixes,
// tasks.md Phase 5.2's decision gate): TECHNIQUE REJECTED, CONFIRMED UNSAFE.
// ============================================================================
//
// The original apply run (no physical device available) shipped this
// unwired, per Phase 5.2's documented fallback. A follow-up wired it into
// `AppDelegate.swift` and installed a release build on a real device
// (iPhone, iOS 26.6) specifically to resolve that open question.
//
// RESULT: reparenting Flutter's `CAMetalLayer`-backed window under the
// secure `UITextField`'s layer renders the ENTIRE app surface solid black --
// not just the protected region, and not just during a screenshot. On
// `RevealSeedShowPage` (tapping "Generate"/reveal seed), the seed was never
// visible at all; the screen was black from the moment the secure overlay
// applied. This is exactly the failure mode design.md's Open Questions
// flagged as a known risk of this community technique with Flutter
// specifically (as opposed to native UIKit apps, where this trick
// originates and is common in banking apps).
//
// DO NOT re-wire this technique as-is. `AppDelegate.swift` was reverted to
// registering only `vault/capture` (layers 2-3, reactive detection) --
// iOS stays at "detect and warn," not "prevent," for screenshot/recording
// exposure. If a future attempt wants to revisit blocking, it needs a
// materially different implementation (the alternate variant design.md
// flags as circulating, or a proper `UIViewController`-hosted secure
// texture instead of raw `CALayer` reparenting) and fresh on-device
// verification -- this exact reparenting approach is now a closed question,
// not an open one.
//
// ============================================================================

import UIKit

/// D11 sketch, variant A: reparents the target window's `CALayer` under the
/// private layer UIKit creates for a `UITextField` with `isSecureTextEntry`,
/// which the system excludes from screenshot/recording composition.
///
/// UNVERIFIED. This is a community technique, not an official Apple API.
/// Known risk: Flutter renders into a `CAMetalLayer`; reparenting it under
/// the secure field's layer has documented reports of blank/frozen surfaces
/// on some iOS versions (design.md Open Questions). See this file's header
/// comment for why that risk was not resolved in this PR.
final class ScreenCaptureProtection {
  static let shared = ScreenCaptureProtection()

  /// D11 constraint 2: apply on 0->1, restore on 1->0, no-op otherwise --
  /// two simultaneously-mounted `SecureScreen`s (a pushed protected route
  /// over a protected route) must not visually break the app.
  private var depth = 0

  private let secureField: UITextField = {
    let field = UITextField()
    field.isSecureTextEntry = true
    return field
  }()

  private weak var reparentedWindow: UIWindow?
  private weak var originalSuperlayer: CALayer?
  private var originalIndex: UInt32 = 0

  private init() {}

  /// Depth 0->1 applies; deeper calls are a no-op. Main-thread only.
  /// D11 constraint 3: never throws -- if the window cannot be resolved or
  /// the secure layer cannot be found, this leaves the window untouched and
  /// silently returns; `AppDelegate`'s handler still reports
  /// `result.success(nil)` either way.
  func apply() {
    dispatchPrecondition(condition: .onQueue(.main))
    depth += 1
    guard depth == 1 else { return }

    guard let window = Self.resolveTargetWindow() else { return }
    guard let secureLayer = secureField.layer.sublayers?.first,
      let superlayer = window.layer.superlayer
    else { return }

    let index = superlayer.sublayers?.firstIndex(where: { $0 === window.layer })
    reparentedWindow = window
    originalSuperlayer = superlayer
    originalIndex = UInt32(index ?? 0)

    superlayer.insertSublayer(window.layer, below: nil)
    secureLayer.addSublayer(window.layer)
  }

  /// Depth 1->0 restores at the original superlayer/index; deeper calls are
  /// a no-op. Main-thread only.
  func restore() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard depth > 0 else { return }
    depth -= 1
    guard depth == 0 else { return }

    guard let window = reparentedWindow, let superlayer = originalSuperlayer else { return }
    superlayer.insertSublayer(window.layer, at: originalIndex)
    reparentedWindow = nil
    originalSuperlayer = nil
  }

  /// D11 constraint 1: never `AppDelegate.window` under the UIScene
  /// lifecycle (`SceneDelegate.swift` declares `FlutterSceneDelegate`).
  /// Resolved fresh at call time from `connectedScenes`.
  private static func resolveTargetWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard scene.activationState == .foregroundActive,
        let windowScene = scene as? UIWindowScene
      else { continue }
      if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return nil
  }
}
