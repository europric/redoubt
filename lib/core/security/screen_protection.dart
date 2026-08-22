/// Android screenshot/screen-recording block via `FLAG_SECURE`, exposed
/// through an in-repo `MethodChannel('vault/screen')` handled by ~15 lines
/// of owned Kotlin in `MainActivity.kt` (design.md's "Exposure Protection"
/// section) — NOT a third-party plugin.
///
/// **iOS (updated, D12)**: it is now FALSE that no native handler is ever
/// registered for this channel on iOS — see the caveat below. What remains
/// true is the OS-level ceiling: no App-Store-safe iOS API can
/// unconditionally block the screenshot shortcut the way Android's
/// `FLAG_SECURE` does, so this channel MUST NOT be documented or treated as
/// an identical guarantee on iOS.
///
/// This PR (`ios-android-platform-parity-fixes` Phase 5.2's decision gate)
/// evaluated the community secure-overlay window-reparenting technique for
/// this channel's `setFlags`/`clearFlags` and did **not** ship it: it could
/// not be verified in this apply run (no physical iOS device available, and
/// Simulator cannot exercise the CAMetalLayer-reparenting question it exists
/// to answer — design.md's Open Questions). No native handler for
/// `vault/screen` is registered on iOS as a result, so [enable]/[disable]
/// remain safe no-ops there today (a [MissingPluginException] is caught,
/// never surfaced) — same observable behavior as before this PR, for a
/// different, now-explicit reason. iOS's app-switcher/background exposure is
/// covered by [SecureScreen]'s Flutter-layer obscuring overlay
/// (`AppLifecycleState`-driven), and active recording/mirroring plus
/// post-hoc screenshot warnings are covered by the new
/// `ScreenCaptureMonitor` (`EventChannel('vault/capture')`, always
/// registered) — reactive detection, not preventive blocking.
///
/// **Unverified without a physical Android device**: whether the native
/// `setFlags`/`clearFlags` handler actually toggles `FLAG_SECURE` and blocks
/// a real screenshot can only be confirmed on-device; see the PR3 manual
/// checklist.
library;

import 'package:flutter/services.dart';

class ScreenProtection {
  static const MethodChannel _channel = MethodChannel('vault/screen');

  const ScreenProtection();

  /// Requests the native side to set `FLAG_SECURE`. No-op (does not throw)
  /// on platforms with no registered handler (iOS).
  Future<void> enable() => _invoke('setFlags');

  /// Requests the native side to clear `FLAG_SECURE`. No-op (does not
  /// throw) on platforms with no registered handler (iOS).
  Future<void> disable() => _invoke('clearFlags');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // No native handler for this channel (iOS) — expected, not an error.
    } on PlatformException {
      // D12 belt-and-braces: the handler contract (see MainActivity.kt and
      // this class's doc comment) says this call must never fail, but widen
      // the catch anyway so a future native regression degrades to a silent
      // no-op instead of an unawaited exception in a caller's `initState`.
      // Does not change today's Android behavior, where the handler cannot
      // throw.
    }
  }
}
