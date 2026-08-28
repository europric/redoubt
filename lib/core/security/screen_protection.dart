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
///
/// **Reference-counted across concurrently-mounted `SecureScreen`s (issue
/// #38)**: [enable]/[disable] used to be unconditional, so a
/// `pushReplacementNamed` transition between two `SecureScreen`s (e.g.
/// `signPin` -> `signature`) could clear `FLAG_SECURE` while the incoming
/// page was still visible -- the outgoing page's `dispose()` fires AFTER
/// the incoming page's `initState()` even at zero transition duration
/// (Flutter defers a deactivated element's `unmount` to `finalizeTree()`),
/// so the native call sequence was `setFlags, setFlags, clearFlags`,
/// leaving protection off while a sensitive screen was still on screen.
/// [_activeScreens] is now a process-wide static reference count, mutated
/// synchronously at call entry (only the native [_invoke] stays
/// asynchronous): native `setFlags` fires only on the 0->1 edge, and
/// `clearFlags` only on the 1->0 edge. Intermediate mounts/unmounts while
/// the count stays above zero make no native call, so overlapping
/// `SecureScreen`s never race each other. [disable] clamps at zero (never
/// negative) so an unpaired extra call is a no-op, but every non-clamped
/// call still decrements, so the true last unmount (count 1->0) always
/// fires `clearFlags` exactly once -- protection can never get stuck on
/// app-wide. [SecureScreen]'s public API and every call site are
/// unchanged.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ScreenProtection {
  static const MethodChannel _channel = MethodChannel('vault/screen');

  /// Process-wide count of currently-mounted `SecureScreen`s sharing this
  /// (canonicalized, `const`-constructed) protection instance. See the
  /// library doc comment for the reference-counting contract.
  static int _activeScreens = 0;

  const ScreenProtection();

  /// Requests the native side to set `FLAG_SECURE` on the 0->1 mount edge.
  /// A no-op native call (but still counted) while another `SecureScreen`
  /// is already mounted. No-op (does not throw) on platforms with no
  /// registered handler (iOS).
  Future<void> enable() {
    final wasIdle = _activeScreens == 0;
    _activeScreens++; // synchronous, before any await
    return wasIdle ? _invoke('setFlags') : Future<void>.value();
  }

  /// Requests the native side to clear `FLAG_SECURE` on the 1->0 unmount
  /// edge. A no-op native call while another `SecureScreen` remains
  /// mounted. Clamped at zero: an unpaired extra call (count already 0) is
  /// a no-op rather than going negative. No-op (does not throw) on
  /// platforms with no registered handler (iOS).
  Future<void> disable() {
    if (_activeScreens == 0) return Future<void>.value(); // clamp
    _activeScreens--; // synchronous, before any await
    return _activeScreens == 0 ? _invoke('clearFlags') : Future<void>.value();
  }

  /// Resets the shared [_activeScreens] counter. For test isolation only —
  /// mirrors `PlatformScreenCaptureMonitor.debugReset()`.
  @visibleForTesting
  static void debugReset() => _activeScreens = 0;

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
