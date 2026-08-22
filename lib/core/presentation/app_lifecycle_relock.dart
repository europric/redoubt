/// Re-arms the app-unlock gate after the app has been backgrounded beyond a
/// grace window (`app-unlock-gate` spec's "Gate Re-Arms After Background
/// Beyond Grace Window" requirement).
///
/// - Records the wall-clock time on [AppLifecycleState.paused].
/// - On [AppLifecycleState.resumed], flips [appUnlocked] to `false` only if
///   more than [gracePeriod] elapsed since that recorded pause -- otherwise
///   a no-op, so a mid-scan camera-permission dialog (which only ever
///   reaches `inactive`, never `paused`) never re-locks.
/// - Deliberately does NOT arm on `inactive` alone (design.md D1):
///   `inactive` fires for permission dialogs, the notification shade, and
///   control center with no true backgrounding. A real background always
///   reaches `paused`, so nothing is lost by ignoring `inactive` here --
///   [SecureScreen] already covers `inactive` separately, for screenshot
///   protection.
///
/// Shape mirrors `_SecureScreenState` (`secure_screen.dart`): a
/// `StatefulWidget` + `WidgetsBindingObserver`, observer added/removed in
/// `initState`/`dispose`, wrapping a `child`.
library;

import 'package:flutter/material.dart';

class AppLifecycleRelock extends StatefulWidget {
  const AppLifecycleRelock({
    super.key,
    required this.appUnlocked,
    required this.child,
    this.gracePeriod = const Duration(seconds: 10),
    this.now = DateTime.now,
  });

  /// Flipped to `false` when a resume is observed beyond [gracePeriod]
  /// after the last [AppLifecycleState.paused] transition. Shared with the
  /// router's `refreshListenable`, so this single flip re-arms the gate.
  final ValueNotifier<bool> appUnlocked;

  final Widget child;

  /// How long the app may stay backgrounded before a resume re-locks it.
  final Duration gracePeriod;

  /// Injectable clock (design.md D2) -- defaults to the const-evaluable
  /// `DateTime.now` tear-off, same precedent as `FlutterUnlockThrottle`
  /// (`unlock_throttle.dart`). A bare `DateTime.now()` is not fakeable by
  /// `tester.pump()`, which never advances wall-clock time.
  final DateTime Function() now;

  @override
  State<AppLifecycleRelock> createState() => _AppLifecycleRelockState();
}

class _AppLifecycleRelockState extends State<AppLifecycleRelock>
    with WidgetsBindingObserver {
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = widget.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt == null) return;
      if (widget.now().difference(pausedAt) > widget.gracePeriod) {
        if (widget.appUnlocked.value) {
          widget.appUnlocked.value = false;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
