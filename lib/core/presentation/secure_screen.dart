/// Wraps a phrase/review/signature screen with capture protection.
///
/// - Android: [ScreenProtection.enable] sets `FLAG_SECURE` on [initState],
///   [ScreenProtection.disable] clears it on [dispose] — blocks screenshots,
///   screen recording, and the app-switcher preview at the OS level.
/// - iOS: `FLAG_SECURE` has no equivalent. [SecureScreenObscuringOverlay] is
///   painted over [child] whenever [AppLifecycleState] is `inactive` or
///   `paused` (app-switcher snapshot), and now also whenever [captureMonitor]
///   reports `isCaptured == true` (design.md D11 layer 2 — active screen
///   recording or AirPlay mirroring, detected via `UIScreen.isCaptured`).
///   [captureMonitor]'s `screenshots` stream (layer 3) surfaces a transient,
///   non-blocking [ScreenshotWarningBanner] after the fact — iOS cannot
///   un-take a screenshot, so this is reactive, not preventive.
///
///   **Reduced guarantee, by design (see `screen_protection.dart`'s and
///   `screen_capture_monitor.dart`'s doc comments)**: this PR's decision gate
///   (design.md D11 / tasks.md Phase 5.2) did not ship the community
///   secure-overlay window-reparenting technique that would have made
///   `ScreenProtection.enable`/`disable` do something on iOS — it could not
///   be verified in this apply run. iOS therefore has no preventive
///   screenshot/recording block; only this reactive obscuring + warning
///   layer, plus the pre-existing background obscuring above.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../security/screen_capture_monitor.dart';
import '../security/screen_protection.dart';

class SecureScreen extends StatefulWidget {
  final Widget child;
  final ScreenProtection protection;

  /// Reactive iOS capture signals (design.md D11 layers 2-3). Defaults to
  /// the real `EventChannel('vault/capture')` adapter; Android and tests
  /// with no native handler degrade to silently-empty streams (see
  /// [PlatformScreenCaptureMonitor]'s doc comment).
  final ScreenCaptureMonitor captureMonitor;

  const SecureScreen({
    super.key,
    required this.child,
    this.protection = const ScreenProtection(),
    this.captureMonitor = const PlatformScreenCaptureMonitor(),
  });

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> with WidgetsBindingObserver {
  /// How long [ScreenshotWarningBanner] stays visible before auto-dismissing.
  static const _bannerDuration = Duration(seconds: 4);

  bool _lifecycleObscured = false;
  bool _captured = false;
  bool _showScreenshotBanner = false;

  StreamSubscription<bool>? _isCapturedSubscription;
  StreamSubscription<void>? _screenshotsSubscription;
  Timer? _bannerDismissTimer;

  bool get _obscured => _lifecycleObscured || _captured;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.protection.enable();
    _isCapturedSubscription = widget.captureMonitor.isCaptured.listen((captured) {
      if (captured != _captured && mounted) {
        setState(() => _captured = captured);
      }
    });
    _screenshotsSubscription = widget.captureMonitor.screenshots.listen((_) {
      if (!mounted) return;
      _bannerDismissTimer?.cancel();
      setState(() => _showScreenshotBanner = true);
      _bannerDismissTimer = Timer(_bannerDuration, () {
        if (mounted) setState(() => _showScreenshotBanner = false);
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.protection.disable();
    _isCapturedSubscription?.cancel();
    _screenshotsSubscription?.cancel();
    _bannerDismissTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldObscure =
        state == AppLifecycleState.inactive || state == AppLifecycleState.paused;
    if (shouldObscure != _lifecycleObscured) {
      setState(() => _lifecycleObscured = shouldObscure);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_obscured) const Positioned.fill(child: SecureScreenObscuringOverlay()),
        if (_showScreenshotBanner)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: ScreenshotWarningBanner(
                onDismiss: () => setState(() => _showScreenshotBanner = false),
              ),
            ),
          ),
      ],
    );
  }
}

/// The transient, non-blocking warning shown after
/// [ScreenCaptureMonitor.screenshots] fires — a screenshot of this screen's
/// content now exists somewhere on the device.
///
/// Deliberately a [Positioned] widget owned by [SecureScreen] and placed
/// inside its own [Stack], NOT a [SnackBar] (design.md D12): [SecureScreen]
/// sits *above* `Scaffold` at every call site (e.g.
/// `seed_show_page.dart`), so a [SnackBar] would resolve to the app-root
/// [ScaffoldMessenger] and render *below* this protection layer, and would
/// require a [MaterialApp] ancestor in every widget test.
class ScreenshotWarningBanner extends StatelessWidget {
  const ScreenshotWarningBanner({super.key, this.onDismiss});

  /// Invoked when the user dismisses the banner early. Optional — the
  /// banner also auto-dismisses on its own after a fixed duration.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.warning_amber, color: colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'A screenshot of this screen was just taken.',
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                icon: Icon(Icons.close, color: colorScheme.onErrorContainer),
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

/// The obscuring cover painted over a phrase/review/signature screen while
/// the app is backgrounded, so the OS app-switcher snapshot never shows the
/// sensitive content.
class SecureScreenObscuringOverlay extends StatelessWidget {
  const SecureScreenObscuringOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: const Center(
        child: Icon(Icons.lock_outline, size: 48),
      ),
    );
  }
}
