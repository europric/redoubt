/// The ONLY `shared_preferences` importer in this codebase (design.md D10,
/// R5's `_gatewayAllowlist`). One key, `install.marker.v1`, value `true`.
/// **Nothing else is ever written to this store** — see
/// `test/config/adapters/shared_preferences_install_marker_store_test.dart`'s
/// own "writes exactly one key" assertion.
///
/// **The adapter catches EVERYTHING (design.md D4)**: every `Exception`,
/// `Error`, `PlatformException`, and `MissingPluginException` — a plugin
/// failure, a platform exception, an unexpected stored type, or any other
/// error — is caught here and reported as [InstallMarkerState.indeterminate].
/// There is no code path from a failure to [InstallMarkerState.absent].
///
/// **One immediate in-process retry (D4)**: [read] retries plugin
/// acquisition + read exactly once before giving up and returning
/// [InstallMarkerState.indeterminate], covering transient initialisation
/// races at no meaningful cost — the happy path is a single cached read
/// (`SharedPreferences.getInstance()` caches its singleton in-process after
/// the first successful call).
library;

import 'package:redoubt/core/security/security.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharedPreferencesInstallMarkerStore implements InstallMarkerStore {
  const SharedPreferencesInstallMarkerStore();

  static const _key = 'install.marker.v1';

  @override
  Future<InstallMarkerState> read() async {
    final first = await _attemptRead();
    if (first != null) return first;
    final retry = await _attemptRead();
    return retry ?? InstallMarkerState.indeterminate;
  }

  /// Returns `null` ONLY when the attempt itself failed (to signal [read]
  /// that a retry is warranted) — otherwise a definitive
  /// [InstallMarkerState], including [InstallMarkerState.absent] when the
  /// read genuinely succeeded and found nothing.
  Future<InstallMarkerState?> _attemptRead() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_key)) return InstallMarkerState.absent;
      // `getBool` casts the raw stored value `as bool?` internally and
      // throws on an unexpected stored type — caught below, surfacing as
      // `indeterminate` rather than propagating a raw TypeError.
      final value = prefs.getBool(_key);
      return value == true
          ? InstallMarkerState.present
          : InstallMarkerState.indeterminate;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wrote = await prefs.setBool(_key, true);
      if (!wrote) return false;
      // Readback confirmation (design.md D4's "write() ... READS IT BACK.
      // `true` only if the readback confirmed it").
      return prefs.getBool(_key) == true;
    } catch (_) {
      return false;
    }
  }
}
