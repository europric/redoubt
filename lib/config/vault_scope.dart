import 'package:flutter/widgets.dart';
import 'package:redoubt/core/security/security.dart';
import 'package:redoubt/features/account/account.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';
import 'package:redoubt/features/seed/seed.dart';
import 'package:redoubt/features/signing/signing.dart';

import 'adapters/cached_account_address_source.dart';
import 'vault_commit_service.dart';
import 'vault_wipe_service.dart';

/// Composes this change's DI graph as a stock-Flutter `InheritedWidget`
/// (design.md's "State management — stock Flutter, zero new dependency"
/// decision — no Riverpod/`provider`).
///
/// Pages/controllers reach dependencies via [VaultScope.of], never by
/// constructing `core/security`/`core/ur` implementations themselves —
/// this is the composition root design.md's route-map section describes,
/// and the ONLY place [seedRepository] is ever the auth-gated
/// [AuthenticatedSeedRepository] decorator rather than the raw storage
/// implementation (so every feature call site is auth-gated by
/// construction, matching PR3's own structural guarantee).
class VaultScope extends InheritedWidget {
  const VaultScope({
    super.key,
    required this.seedRepository,
    required this.sealedVaultRepository,
    required this.unlockThrottle,
    required this.authService,
    required this.mnemonicService,
    required this.accountDerivationService,
    required this.transactionSigner,
    required this.accountController,
    required this.accountCache,
    required this.vaultCommitService,
    required this.vaultWiper,
    required this.vaultState,
    required this.vaultStateProbe,
    required this.onboardingDraft,
    required this.unlockPreferences,
    required this.appUnlocked,
    required super.child,
  });

  /// Builds the production DI graph: `FlutterSecureSeedRepository` wrapped
  /// in `AuthenticatedSeedRepository` (biometric-gated reads/writes/
  /// delete), `LocalAuthAuthService`, `Bip39MnemonicService`, and
  /// `Bip32AccountDerivationService`.
  ///
  /// [baseSeedRepository] is accepted so `main.dart` can reuse the exact
  /// storage instance it already used for its pre-`runApp` `hasSeed()`
  /// presence check (see that file's own doc comment on why the check
  /// bypasses this decorator) rather than constructing a second one.
  ///
  /// [vaultStateProbe] is likewise accepted so `main.dart` can reuse the
  /// exact probe instance it already ran once, synchronously, before
  /// `runApp` (vault-secure-storage-redesign PR6) to compute [vaultState]'s
  /// initial value.
  factory VaultScope.production({
    Key? key,
    SecureSeedRepository? baseSeedRepository,
    VaultStateProbe? vaultStateProbe,
    UnlockPreferences? unlockPreferences,
    VaultWiper? vaultWiper,
    ValueNotifier<bool>? appUnlocked,
    required ValueNotifier<VaultState> vaultState,
    required Widget child,
  }) {
    final base = baseSeedRepository ?? const FlutterSecureSeedRepository();
    final stateProbe = vaultStateProbe ?? const FlutterVaultStateProbe();
    final preferences = unlockPreferences ?? const FlutterUnlockPreferences();
    // ios-android-platform-parity-fixes PR1 (design.md D13): `main.dart`
    // constructs ONE `VaultWipeService` instance and passes it here AND to
    // `FreshInstallGate` (the "same instance-reuse convention as
    // `baseSeedRepository`/`vaultStateProbe`" this factory already
    // follows). Defaulted so every pre-PR1 test that omits this parameter
    // keeps working unchanged.
    final wiper =
        vaultWiper ??
        VaultWipeService.production(
          seedRepository: base,
          unlockPreferences: preferences,
        );
    // Always starts `false` (biometric-unlock-onboarding design.md D5) --
    // a cold launch has never passed the app-unlock gate yet, even if the
    // vault turns out to be `current`.
    final unlocked = appUnlocked ?? ValueNotifier<bool>(false);
    final authenticatedSeedRepository = AuthenticatedSeedRepository(
      repository: base,
      authService: LocalAuthAuthService(),
    );
    final derivationService = Bip32AccountDerivationService();
    // Unlock-free by construction (design.md's "Public account cache
    // lives in `flutter_secure_storage` under its own key, read
    // undecorated" decision) — deliberately NOT wrapped in
    // `AuthenticatedSeedRepository`, unlike [authenticatedSeedRepository]
    // above.
    const accountCache = FlutterPublicAccountCache();
    // Same reasoning as [accountCache] — the v1 blob repository, throttle
    // state, and AuthService.isSupported()-gated hardware wrap are all
    // orchestrated explicitly by `EthTransactionSigner`/`VaultCommitService`
    // themselves (vault-secure-storage-redesign PR7), never gated by
    // `AuthenticatedSeedRepository`.
    const sealedVaultRepository = FlutterSealedVaultRepository();
    const unlockThrottle = FlutterUnlockThrottle();
    final authService = LocalAuthAuthService();
    // Legacy-cleanup only now — see `VaultCommitService`'s own doc comment
    // on why this is deliberately the RAW (non-biometric-gated) repository,
    // not [authenticatedSeedRepository].
    final vaultCommitService = VaultCommitService(
      seedRepository: base,
      sealedVaultRepository: sealedVaultRepository,
      derivationService: derivationService,
      accountCache: accountCache,
    );
    return VaultScope(
      key: key,
      seedRepository: authenticatedSeedRepository,
      sealedVaultRepository: sealedVaultRepository,
      unlockThrottle: unlockThrottle,
      authService: authService,
      mnemonicService: Bip39MnemonicService(),
      accountDerivationService: derivationService,
      // Vault-secure-storage-redesign PR7: signing now orchestrates its own
      // PIN unlock + hardware wrap + v1 blob read (see this constructor's
      // own doc comment) instead of going through the legacy auth-gated
      // seed repository.
      transactionSigner: EthTransactionSigner(
        sealedVaultRepository: sealedVaultRepository,
        unlockThrottle: unlockThrottle,
        authService: authService,
        // Wraps the same [accountCache] instance as [accountCache]/
        // [accountController] below (seed-passphrase-25th-word design.md
        // D5) — required, not nullable, so the signing-time address-match
        // guard always reads the real commit-time cache; a nullable seam
        // would let a fake silently disable the guard.
        // hexagonal-architecture-refactor PR4 (design.md D6): bound via the
        // composition-root adapter rather than passing [accountCache]'s
        // full `PublicAccountCache` interface straight into `signing/data`.
        committedAddressSource: const CachedAccountAddressSource(accountCache),
      ),
      // Same [derivationService] instance as [accountDerivationService] —
      // constructed once here, eagerly, alongside the other singletons, so
      // the Account route's builder reuses this exact instance instead of
      // constructing a fresh `AccountController` (and re-triggering
      // biometric auth + derivation) on every route rebuild. See this
      // field's own doc comment for the full rationale.
      accountController: AccountController(
        seedRepository: authenticatedSeedRepository,
        derivationService: derivationService,
        accountCache: accountCache,
      ),
      accountCache: accountCache,
      vaultCommitService: vaultCommitService,
      vaultWiper: wiper,
      vaultState: vaultState,
      vaultStateProbe: stateProbe,
      onboardingDraft: OnboardingDraft(),
      unlockPreferences: preferences,
      appUnlocked: unlocked,
      child: child,
    );
  }

  /// The (usually auth-gated) seed repository every feature controller
  /// depends on. Vault-secure-storage-redesign PR7: now used only for
  /// [AccountController.repairCache]'s legacy-entropy read and
  /// [VaultCommitService]'s legacy-key cleanup delete — the real seed-commit
  /// and signing paths use [sealedVaultRepository] instead.
  final SecureSeedRepository seedRepository;

  /// The v1 sealed-blob storage seam — `VaultCommitService`/
  /// `EthTransactionSigner`'s dependency (vault-secure-storage-redesign
  /// PR7). Ungated, same as [accountCache]/[unlockThrottle] — see
  /// `sealed_vault_repository.dart`'s own doc comment.
  final SealedVaultRepository sealedVaultRepository;

  /// The failed-unlock-attempt throttle `EthTransactionSigner`/
  /// `PinEntryPage` depend on (vault-secure-storage-redesign PR7).
  final UnlockThrottle unlockThrottle;

  /// The hardware-wrap (biometric/passcode) service `EthTransactionSigner`
  /// depends on directly now (vault-secure-storage-redesign PR7) — no
  /// longer only reachable via the [AuthenticatedSeedRepository] decorator.
  final AuthService authService;

  final MnemonicService mnemonicService;

  final AccountDerivationService accountDerivationService;

  /// The PIN-unlock-and-hardware-wrap-aware signer every signing-flow
  /// controller depends on (vault-secure-storage-redesign PR7).
  final TransactionSigner transactionSigner;

  /// The Account screen's controller, owned here as a stable singleton for
  /// the app's lifetime — intentionally NOT constructed fresh per `/account`
  /// route builder invocation. go_router re-invokes a matched route's
  /// `builder` more than once per logical "screen visit" (e.g. navigating
  /// Account → Scan → back), and `AccountPage`'s `initState` only ever
  /// calls `.load()` once per `_AccountPageState` object; a fresh
  /// controller on a later builder invocation would never get loaded,
  /// rendering a blank address/QR. Keeping this instance stable — reset
  /// explicitly via [refreshVaultState] on seed change — fixes that and, as
  /// a side effect, stops re-running biometric auth on every re-render.
  final AccountController accountController;

  /// The unlock-free public account cache [accountController] reads from
  /// on [AccountController.load] and repairs via [AccountController.
  /// repairCache] — exposed here too so other composition-root-level call
  /// sites (e.g. a future vault-reset cache clear) can reach it without
  /// going through the controller.
  final PublicAccountCache accountCache;

  /// Orchestrates a seed-commit (vault-secure-storage-redesign PR7): seals
  /// the entropy under a PIN as a v1 blob, writes it, derives + caches the
  /// public account data, and cleans up any legacy key. The sole production
  /// call site is the PIN-setup step reached from `SeedVerifyController`/
  /// `SeedImportController` (`app_router.dart`'s `generate.pinSetup`/
  /// `import.pinSetup` routes).
  final VaultCommitService vaultCommitService;

  /// The single, shared ordered on-device wipe (design.md D1/D13) —
  /// `app_router.dart`'s `deleteAccountPin` route injects this into
  /// `VaultResetController` (called with `includeIntroSeen: false`); the
  /// SAME instance is also passed to `FreshInstallGate` in `main.dart`
  /// (called with `includeIntroSeen: true`), so there is exactly one wipe
  /// implementation in the running app, not two independently-drifting
  /// ones.
  final VaultWiper vaultWiper;

  /// The current [VaultState] — the same value `AppRouter.get`'s `redirect`
  /// guard listens to via `refreshListenable` (vault-secure-storage-redesign
  /// PR6: moved from a bare `ValueNotifier<bool>` "has a seed" flag to the
  /// four-way [VaultState], per design.md's "Old-format detection" section).
  /// Callers that write or delete the vault MUST call [refreshVaultState]
  /// afterwards so the router reacts immediately ([vaultState] does not
  /// update itself).
  final ValueNotifier<VaultState> vaultState;

  /// Probes storage for the current [VaultState] — key presence + header
  /// parse only, no decrypt/PIN/biometric (see that class's own doc
  /// comment). [refreshVaultState] is the only caller.
  final VaultStateProbe vaultStateProbe;

  /// The onboarding flow's in-memory PIN carrier (biometric-unlock-onboarding
  /// design.md D3) — filled by `/onboarding/pin`, consumed (and
  /// relinquished) by the seed-commit routes' `commitWithDraft` call, and
  /// zeroized by [refreshVaultState] on every commit/deletion and on
  /// re-entering `/onboarding/pin`. A stable singleton, same lifetime as
  /// [vaultCommitService].
  final OnboardingDraft onboardingDraft;

  /// The two-flag onboarding/app-unlock preference seam
  /// (`onboarding.intro.seen.v1`, `vault.unlock.biometric.v1`) — read by the
  /// router's onboarding-entry redirect and written by
  /// `BiometricEnrollmentController`/the intro page's continue callback.
  final UnlockPreferences unlockPreferences;

  /// The `app-unlock-gate` capability's in-memory unlock flag
  /// (biometric-unlock-onboarding design.md D5) -- always starts `false` on
  /// a fresh app launch, flipped to `true` by `AppRouter`'s `/unlock` route
  /// after a successful biometric or PIN unlock (`markUnlocked()`), and
  /// reset to `false` by [refreshVaultState] whenever the freshly-probed
  /// [VaultState] is no longer [VaultState.current]. The SAME instance must
  /// also be passed to `AppRouter.get`'s own `appUnlocked` parameter so the
  /// router's redirect guard observes this reset live.
  final ValueNotifier<bool> appUnlocked;

  static VaultScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<VaultScope>();
    assert(scope != null, 'No VaultScope found in context');
    return scope!;
  }

  /// Re-runs [vaultStateProbe] and updates [vaultState] — call this after
  /// `SeedVerifyController.commitWithPin`, `SeedImportController.commitWithPin`,
  /// `VaultResetController.confirmReset` succeeds, or after catching a
  /// `MalformedVaultBlobFailure`/`UnsupportedVaultVersionFailure` during
  /// signing (routes to the recovery screen via the redirect guard).
  ///
  /// **Cutover complete (vault-secure-storage-redesign PR7)**: [vaultCommitService]
  /// now writes a real `vault.seed.v1` blob, so a real commit re-probes as
  /// [VaultState.current] — the PR6-era [VaultState.legacy] limitation
  /// documented here previously no longer applies.
  ///
  /// **No new reset mechanism for account deletion (delete-account-secure-
  /// wipe design.md D6)**: [accountController] is the only stateful
  /// singleton this scope holds, and this method already resets it on
  /// every call. Every other controller (`RevealSeed`, `SignReview`,
  /// `Scan`, `SeedGenerate`/`Verify`/`Import`, and this change's
  /// `VaultResetController`) is built fresh per `GoRoute.builder` and dies
  /// with its matched-route stack when the redirect guard replaces it —
  /// `VaultResetController.confirmReset` succeeding is exactly such a
  /// case, so nothing beyond the existing `accountController.reset()` call
  /// below is needed to leave no in-memory trace of the deleted account.
  ///
  /// **Also zeroizes [onboardingDraft]** (biometric-unlock-onboarding
  /// design.md D3: "Cleared by `refreshVaultState()` (every commit and
  /// every deletion)") — a successful commit already relinquished the
  /// draft's PIN via `takePin()`, so this is a harmless no-op there; after
  /// an account deletion it defensively discards any stray held PIN.
  Future<void> refreshVaultState() async {
    final probed = await vaultStateProbe.probe();
    vaultState.value = probed;
    // biometric-unlock-onboarding design.md D5: "refreshVaultState() sets
    // appUnlocked = false whenever the probed state is not current" -- e.g.
    // after a full account-deletion wipe, so a subsequently re-onboarded
    // vault is never treated as already-unlocked. Deliberately does NOT
    // flip this to `true` on its own when [probed] IS current -- only the
    // seed-commit routes' explicit `markUnlocked()` call (after this
    // method returns) or a real biometric/PIN pass at `/unlock` may do
    // that.
    if (probed != VaultState.current) {
      appUnlocked.value = false;
    }
    accountController.reset();
    onboardingDraft.clear();
  }

  @override
  bool updateShouldNotify(VaultScope oldWidget) =>
      seedRepository != oldWidget.seedRepository ||
      sealedVaultRepository != oldWidget.sealedVaultRepository ||
      unlockThrottle != oldWidget.unlockThrottle ||
      authService != oldWidget.authService ||
      mnemonicService != oldWidget.mnemonicService ||
      accountDerivationService != oldWidget.accountDerivationService ||
      transactionSigner != oldWidget.transactionSigner ||
      accountController != oldWidget.accountController ||
      accountCache != oldWidget.accountCache ||
      vaultCommitService != oldWidget.vaultCommitService ||
      vaultWiper != oldWidget.vaultWiper ||
      vaultState != oldWidget.vaultState ||
      vaultStateProbe != oldWidget.vaultStateProbe ||
      onboardingDraft != oldWidget.onboardingDraft ||
      unlockPreferences != oldWidget.unlockPreferences ||
      appUnlocked != oldWidget.appUnlocked;
}
