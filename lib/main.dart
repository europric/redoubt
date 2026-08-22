import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:redoubt/config/adapters/shared_preferences_install_marker_store.dart';
import 'package:redoubt/config/config.dart';
import 'package:redoubt/config/vault_scope.dart';
import 'package:redoubt/config/vault_wipe_service.dart';
import 'package:redoubt/core/presentation/app_lifecycle_relock.dart';
import 'package:redoubt/core/presentation/app_theme.dart';
import 'package:redoubt/core/presentation/bootstrap_failure_app.dart';
import 'package:redoubt/core/security/flutter_secure_seed_repository.dart';
import 'package:redoubt/core/security/fresh_install_gate.dart';
import 'package:redoubt/core/security/unlock_preferences.dart';
import 'package:redoubt/core/security/vault_blob.dart';
import 'package:redoubt/core/security/vault_state_probe.dart';

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  const seedRepository = FlutterSecureSeedRepository();
  const unlockPreferences = FlutterUnlockPreferences();
  // ios-android-platform-parity-fixes PR1 (design.md D7/D13): the single,
  // shared wipe implementation, constructed once and reused by BOTH the
  // gate below (`includeIntroSeen: true`) and `VaultScope.production`
  // (`includeIntroSeen: false`, via `VaultResetController`) — same
  // instance-reuse convention as [seedRepository]/[vaultStateProbe].
  final wiper = VaultWipeService.production(
    seedRepository: seedRepository,
    unlockPreferences: unlockPreferences,
  );

  // The fresh-install gate MUST run strictly before `vaultStateProbe.probe()`
  // below, with nothing interleaved (design.md D7): `probe()` and
  // `getIntroSeen()` are pure reads of the same secure store the wipe may
  // just have emptied, so running them after the gate means they observe
  // post-wipe reality by construction.
  final gate = FreshInstallGate(
    markerStore: const SharedPreferencesInstallMarkerStore(),
    wiper: wiper,
  );
  final gateResult = await gate.run();
  if (gateResult == FreshInstallGateResult.storageUnavailable) {
    runApp(const BootstrapFailureApp());
    FlutterNativeSplash.remove();
    return;
  }

  // Non-decrypting key-presence + header-parse probe, deliberately NOT
  // going through the biometric-gated `AuthenticatedSeedRepository`
  // decorator — this must decide which screen to land on (onboarding vs.
  // recovery vs. account) without ever prompting biometrics or a PIN
  // (design.md's "Old-format detection" section: key presence + header
  // parse only, vault-secure-storage-redesign PR6). The same probe instance
  // is reused by `VaultScope.production` below instead of constructing a
  // second one; likewise the same [seedRepository] storage instance is
  // reused instead of constructing a second one. Both run AFTER the gate
  // above, so they see post-wipe truth (design.md D7).
  const vaultStateProbe = FlutterVaultStateProbe();
  final vaultState = ValueNotifier<VaultState>(await vaultStateProbe.probe());
  // `app-unlock-gate` capability (biometric-unlock-onboarding design.md D5):
  // `appUnlocked` always starts `false` -- a cold launch has never passed
  // the gate yet, even when the vault turns out to be `current`.
  // `introSeen` is seeded once, here, from the persisted flag; the ONLY
  // production writer of the flag itself (`AppRouter`'s onboarding-intro
  // route) also keeps this in-memory copy in sync so a live redirect
  // re-evaluation (via `refreshListenable`) sees the update immediately.
  final appUnlocked = ValueNotifier<bool>(false);
  final introSeen = ValueNotifier<bool>(await unlockPreferences.getIntroSeen());

  runApp(
    VaultScope.production(
      baseSeedRepository: seedRepository,
      vaultStateProbe: vaultStateProbe,
      unlockPreferences: unlockPreferences,
      vaultWiper: wiper,
      appUnlocked: appUnlocked,
      vaultState: vaultState,
      child: MainApp(
        vaultState: vaultState,
        appUnlocked: appUnlocked,
        introSeen: introSeen,
      ),
    ),
  );
  FlutterNativeSplash.remove();
}

class MainApp extends StatelessWidget {
  const MainApp({
    super.key,
    required this.vaultState,
    required this.appUnlocked,
    required this.introSeen,
  });

  final ValueNotifier<VaultState> vaultState;
  final ValueNotifier<bool> appUnlocked;
  final ValueNotifier<bool> introSeen;

  @override
  Widget build(BuildContext context) {
    // `app-unlock-gate` spec's "Gate Re-Arms After Background Beyond Grace
    // Window" requirement (design.md D3): wraps the router, sharing the
    // SAME [appUnlocked] notifier the redirect guard already reacts to via
    // `refreshListenable`, so a relock re-drives that guard with no other
    // changes needed here.
    return AppLifecycleRelock(
      appUnlocked: appUnlocked,
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: AppRouter.get(
          vaultState: vaultState,
          appUnlocked: appUnlocked,
          introSeen: introSeen,
        ),
      ),
    );
  }
}
