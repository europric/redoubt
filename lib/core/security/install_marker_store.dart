/// The fakeable port over the fresh-install marker
/// (`ios-android-platform-parity-fixes` design.md D4).
///
/// **This is the single most important shape in this change.** A
/// `Future<bool>` that throws invites `catch (_) => false` at some future
/// call site, and `false` would mean "wipe". A total three-valued enum
/// makes that dangerous value unreachable by accident: every production
/// implementation MUST catch every failure (plugin, platform, decode,
/// unexpected type) internally and report [InstallMarkerState.indeterminate]
/// instead of letting an exception propagate. There is no code path from a
/// failure to [InstallMarkerState.absent].
///
/// Zero imports outside `dart:*` — same reasoning as `vault_wiper.dart`.
library;

/// The result of reading the fresh-install marker. Deliberately NOT a
/// `bool` — see this file's own doc comment.
enum InstallMarkerState {
  /// The marker is present: this device has already completed a wipe (or
  /// was never a fresh install to begin with).
  present,

  /// A successful read found nothing. This is the ONLY value that may
  /// trigger [FreshInstallGate] to wipe.
  absent,

  /// The read did not produce a definitive answer — a plugin failure, a
  /// platform exception, an unexpected stored type, or any other error.
  /// NEVER treated as [absent]; [FreshInstallGate] refuses to run instead.
  indeterminate,
}

/// The fakeable boundary over the fresh-install marker's storage.
abstract interface class InstallMarkerStore {
  /// Reads the current marker state. NEVER throws — any failure (plugin,
  /// platform, decode, unexpected type) is reported as
  /// [InstallMarkerState.indeterminate]. Only a successful read that found
  /// nothing may return [InstallMarkerState.absent]; that value is the sole
  /// trigger for an irreversible wipe.
  Future<InstallMarkerState> read();

  /// Writes the marker and reads it back to confirm. Returns `true` ONLY if
  /// the readback confirmed the write. NEVER throws.
  Future<bool> write();
}
