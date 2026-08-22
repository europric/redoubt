import 'package:flutter/material.dart';

/// Blocking, dead-end recovery screen shown whenever `AppRouter.get`'s
/// redirect guard sees [VaultState.legacy] or [VaultState.unreadable]
/// (design.md's "Old-format detection" section / `secure-seed-storage`
/// spec's "Old-Format Blob Detection Triggers Re-Import, Never Silent
/// Migration Or Crash" requirement).
///
/// **No back affordance, by construction**: `AppRouter.get`'s `redirect`
/// callback reaches this route the same way it reaches `/` for
/// [VaultState.none] or `/account` for [VaultState.current] — a full
/// redirect (go_router's `go`-equivalent replace, per this codebase's own
/// push-vs-go convention documented in `app_router.dart`), never a `push`.
/// That alone already leaves nothing on the Navigator stack to pop into.
/// [PopScope] below is a second, explicit layer of the same guarantee (e.g.
/// in case a future call site ever `pushNamed`s here directly) — this is a
/// dead-end screen, not a normal step in a reversible flow.
///
/// **Non-goals of this PR (vault-secure-storage-redesign PR6, Phase 7)**:
/// neither [onReImport] nor [onGenerateNew] can actually escape
/// [VaultState.legacy] yet — `VaultCommitService` still only writes the
/// legacy `vault.seed.entropy` key (v0, from PR2), so completing either flow
/// still reads back as [VaultState.legacy] and redirects straight back here.
/// That cutover is PR7/Phase 8's job. The buttons are still wired here so
/// the screen is not a functional dead end from the user's perspective —
/// they can still begin either flow — it just does not yet resolve the
/// underlying format problem.
class RecoveryPage extends StatelessWidget {
  const RecoveryPage({
    super.key,
    required this.onReImport,
    required this.onGenerateNew,
  });

  /// Invoked when the user chooses to re-import their existing recovery
  /// phrase (routes into the same `/import` flow as normal onboarding).
  final VoidCallback onReImport;

  /// Invoked when the user chooses to generate a brand-new seed instead
  /// (routes into the same `/generate` flow as normal onboarding).
  final VoidCallback onGenerateNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Vault format changed'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.security_update_warning_outlined,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'This wallet\'s secure storage format has changed.',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  'The vault stored on this device uses an older storage '
                  'format that this version can no longer treat as usable. '
                  'It cannot be automatically upgraded, and it is never '
                  'silently reused. To continue, re-import your existing '
                  'recovery phrase or generate a brand-new one.',
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('recoveryReImportButton'),
                  onPressed: onReImport,
                  child: const Text('Re-import my recovery phrase'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('recoveryGenerateNewButton'),
                  onPressed: onGenerateNew,
                  child: const Text('Generate a new recovery phrase'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
