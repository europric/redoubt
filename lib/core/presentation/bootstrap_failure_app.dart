import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The terminal, non-navigable screen `main.dart` renders in place of the
/// normal app when `FreshInstallGate` reports `FreshInstallGateResult.
/// storageUnavailable` (`ios-android-platform-parity-fixes` design.md D5).
///
/// The fresh-install marker could not be read or written with certainty,
/// so the app MUST NOT proceed to any wallet-creation-capable screen —
/// "refuse to run" is the entire point (design.md's cost table: refusing
/// destroys nothing and is recoverable by simply relaunching, whereas
/// proceeding without wiping risks wiping a wallet created THIS session on
/// a later, successful read).
///
/// **Deliberately NOT a `GoRoute`** — this is a plain `MaterialApp`, built
/// and passed straight to `runApp()` from `main.dart`, entirely outside
/// `AppRouter`'s route table. It must stay structurally unreachable from
/// any in-app navigation, not merely unlinked from the UI.
class BootstrapFailureApp extends StatelessWidget {
  const BootstrapFailureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Something went wrong starting the app. Please close and '
                'reopen it.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
