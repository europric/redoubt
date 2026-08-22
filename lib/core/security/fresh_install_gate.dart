/// The bootstrap-time orchestrator that combines [InstallMarkerStore] and
/// [VaultWiper] into a single decision (`ios-android-platform-parity-fixes`
/// design.md D5/D6).
///
/// **Framework-free, by construction (D6)**: this file imports ONLY the two
/// ports below, both of which live in `core/security` — R2's
/// `coreOther -> coreOther` rule permits it, and `tool/check_architecture.dart`
/// then keeps it free of Flutter, plugins, and `features/**` forever. This
/// is the one piece of logic in this change whose bug class is irreversible
/// fund loss, and it is a pure function of two enums, unit-testable with
/// two hand-written fakes.
///
/// **The safety argument is structural, not procedural**: the only value
/// that can reach the wipe trigger is [InstallMarkerState.absent], and the
/// only producer of that value is a storage read that both succeeded AND
/// found nothing. Every other outcome — an exception escaping [read] (this
/// class defends against that too, even though the port contracts it away),
/// [InstallMarkerState.indeterminate], or an unconfirmed [write] — maps to
/// [FreshInstallGateResult.storageUnavailable], never to a wipe and never
/// to a silent proceed.
///
/// **"Mark as soon as the vault is provably unrecoverable" (design.md D5's
/// correction to "mark only on a fully clean wipe")**: [VaultWipeOutcome.
/// irreversible] writes the marker exactly like [VaultWipeOutcome.complete]
/// does. Marking only on `complete` would create a wipe LOOP that destroys
/// a wallet the user creates after a partially-failed wipe: step 1 of the
/// wipe committed (the old vault is gone), a later best-effort step failed,
/// the marker is withheld, the user creates a NEW wallet, and the next cold
/// start still sees an absent marker and wipes the wallet they just made.
/// [VaultWipeOutcome.aborted] is the one outcome that never writes the
/// marker — nothing was deleted, so the old vault is still readable and
/// retrying next launch is both safe and correct.
library;

import 'install_marker_store.dart';
import 'vault_wiper.dart';

/// The two possible outcomes of [FreshInstallGate.run].
enum FreshInstallGateResult {
  /// Safe to proceed to the rest of bootstrap (`FlutterVaultStateProbe.
  /// probe()`, then `runApp`).
  ready,

  /// The marker could not be read or written with certainty. The caller
  /// MUST NOT proceed to any wallet-creation-capable screen — render a
  /// terminal, non-navigable failure screen instead (`BootstrapFailureApp`).
  storageUnavailable,
}

/// Combines [InstallMarkerStore] and [VaultWiper] into the single
/// bootstrap-time fresh-install decision. See this file's own doc comment
/// for the full safety argument.
class FreshInstallGate {
  const FreshInstallGate({required this.markerStore, required this.wiper});

  final InstallMarkerStore markerStore;
  final VaultWiper wiper;

  /// Runs the D5 decision table once. Never throws — every failure mode
  /// (including one that violates a port's own "never throws" contract)
  /// resolves to [FreshInstallGateResult.storageUnavailable].
  Future<FreshInstallGateResult> run() async {
    InstallMarkerState state;
    try {
      state = await markerStore.read();
    } catch (_) {
      // Defense in depth: [InstallMarkerStore.read] is contracted to never
      // throw, but the ONLY value that may reach the wipe trigger below is
      // a definitively-successful [InstallMarkerState.absent] read, so an
      // escaping exception must never be treated as "absent".
      state = InstallMarkerState.indeterminate;
    }

    switch (state) {
      case InstallMarkerState.present:
        return FreshInstallGateResult.ready;

      case InstallMarkerState.indeterminate:
        // Stricter than "proceed without wiping": a genuinely fresh
        // install whose marker read fails transiently could let the user
        // create a wallet this same session, which a later successful read
        // would then wipe. Refusing to run destroys nothing and is
        // recoverable by relaunching (design.md D5's cost table).
        return FreshInstallGateResult.storageUnavailable;

      case InstallMarkerState.absent:
        final outcome = await wiper.wipe(includeIntroSeen: true);
        if (outcome == VaultWipeOutcome.aborted) {
          // Nothing was deleted -- the old vault is still readable. Do NOT
          // mark; proceed anyway (retried next cold start).
          return FreshInstallGateResult.ready;
        }

        // irreversible or complete: the vault is provably unrecoverable
        // now, so the marker must be written before proceeding, or a
        // second launch would wipe again (the anti-wipe-loop rule).
        bool confirmed;
        try {
          confirmed = await markerStore.write();
        } catch (_) {
          confirmed = false;
        }
        return confirmed
            ? FreshInstallGateResult.ready
            : FreshInstallGateResult.storageUnavailable;
    }
  }
}
