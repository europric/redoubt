import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';
import 'package:redoubt/features/account/account.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';
import 'package:redoubt/features/seed/seed.dart';
import 'package:redoubt/features/settings/settings.dart';
import 'package:redoubt/features/signing/signing.dart';
import 'package:redoubt/features/vault/vault.dart';

import '../vault_scope.dart';

/// Composes go_router with `VaultScope` (design.md's "Route Map" section).
///
/// `seed_setup_choice_page.dart` is unmodified — the `onGenerate`/`onImport`
/// callbacks it already exposes are injected here, at the composition
/// root, exactly as design.md specifies.
///
/// ## Navigation: `push` vs `go`
///
/// Every forward navigation below is `context.pushNamed(...)` EXCEPT the
/// two seed-commit points (`generate.verify` -> `account` and `import` ->
/// `account`), which stay `context.goNamed('account')`. The rule: `push`
/// for every step that hasn't persisted anything yet, so the user can
/// freely back out (generate a different phrase, cancel importing, cancel
/// scanning/reviewing) — `go`/replace only once a seed is actually written
/// to secure storage, so there is never a way to navigate back into an
/// already-committed seed-entry flow.
///
/// **Exception (design.md D6, account-screen-redesign-and-lifecycle-auth-
/// gate PR3)**: the `signature` route's `onDone` also calls
/// `context.goNamed('account')`, even though signing itself persists
/// nothing. This knowingly overrides the "re-view a just-produced
/// signature" rationale this comment previously stated for that one
/// screen — the signature screen is terminal by explicit product decision,
/// so both its confirm button and its intercepted hardware/gesture back
/// collapse the scan/review/pin stack to `/account` in one hop instead.
///
/// This works because these are all flat sibling `GoRoute`s (no
/// `ShellRoute`/nesting), so go_router's matched-route stack only ever
/// contains routes reached by explicit `push`; `go`/`goNamed` always
/// resets that stack to just the target location (see e.g. the `redirect`
/// callback below, which also only ever deals with a single
/// `state.matchedLocation`). So `goNamed('account')` after a `push`-built
/// stack (Generate -> Show -> Verify, or Import) discards that entire
/// stack, and `Navigator.canPop` is `false` again on `/account` — exactly
/// the desired "can't back into a committed flow" behavior.
class AppRouter {
  /// [vaultState] both drives the `redirect` guard below AND is the
  /// `refreshListenable` go_router re-evaluates that guard against, so a
  /// live change (e.g. `VaultScope.refreshVaultState()` after a successful
  /// verify/import/reset) redirects immediately without any explicit
  /// navigation call.
  ///
  /// **Redirects** (design.md's "Old-format detection" section):
  /// - [VaultState.none] -> `/` (onboarding — no separate empty-state
  ///   screen).
  /// - [VaultState.legacy] / [VaultState.unreadable] -> `/vault/recover`
  ///   (blocking, no back affordance — see `recovery_page.dart`).
  /// - [VaultState.current] -> `/account`.
  ///
  /// Only `/` and `/account*` are ever redirected away from — `/generate*`
  /// and `/import` stay reachable in every [VaultState] (unchanged from
  /// this router's pre-PR6 behavior), so the recovery screen's re-import/
  /// generate-new buttons can still navigate into those flows.
  ///
  /// [appUnlocked]/[introSeen] (biometric-unlock-onboarding design.md D5):
  /// the `app-unlock-gate` capability's own gate state. Both are OPTIONAL
  /// here purely so the many pre-PR4 tests unrelated to this gate need no
  /// changes -- omitting them defaults to an always-unlocked, intro-already-
  /// seen router (today's pre-PR4 behavior). Production (`main.dart`)
  /// always passes the real notifiers explicitly, and MUST pass the SAME
  /// [appUnlocked] instance also given to `VaultScope`'s own `appUnlocked`
  /// field, so [VaultScope.refreshVaultState]'s reset is observed live by
  /// this redirect guard via [refreshListenable].
  static GoRouter get({
    required ValueNotifier<VaultState> vaultState,
    ValueNotifier<bool>? appUnlocked,
    ValueNotifier<bool>? introSeen,
  }) {
    final unlocked = appUnlocked ?? ValueNotifier<bool>(true);
    final seenIntro = introSeen ?? ValueNotifier<bool>(false);

    void markUnlocked() => unlocked.value = true;

    return GoRouter(
      initialLocation: '/',
      refreshListenable: Listenable.merge([vaultState, unlocked, seenIntro]),
      redirect: (context, state) async {
        final location = state.matchedLocation;
        switch (vaultState.value) {
          case VaultState.current:
            // `app-unlock-gate` spec's "Gate Enforced Before Account Screen
            // When Vault Is Current" requirement (design.md D5): deny-by-
            // default over EVERY location except `/unlock` itself while
            // locked, so a deep link (e.g. `/account/sign`) can never bypass
            // the gate. Once unlocked, `/`, `/unlock`, and any stray
            // `/onboarding*` location redirect to `/account` -- same
            // "onboarding/unlock is done, get to the destination" rule the
            // pre-existing `/` -> `/account` redirect already applied.
            if (!unlocked.value) {
              return location == '/unlock' ? null : '/unlock';
            }
            if (location == '/' ||
                location == '/unlock' ||
                location.startsWith('/onboarding')) {
              return '/account';
            }
            return null;
          case VaultState.none:
            if (location.startsWith('/account')) return '/';
            // `onboarding-flow` spec's "Three-Step Guided Sequence For
            // First-Ever Setup" requirement: `/` (the generate/import picker)
            // is only reachable once the onboarding PIN-setup step has
            // already filled `OnboardingDraft` (biometric-unlock-onboarding
            // design.md's Route Map / D5's `VaultState.none` row). `/onboarding*`
            // and `/generate*`/`/import` stay always-reachable (unchanged, no
            // redirect target below).
            if (location == '/') {
              final vault = VaultScope.of(context);
              if (!vault.onboardingDraft.hasPin) {
                // Post-deletion re-onboarding skips the intro explainer
                // (`onboarding-flow` spec's "Post-Deletion Re-Onboarding Skips
                // The Intro Explainer" requirement) — `introSeen` survives
                // account deletion (design.md's flag-wipe table), so a
                // returning user who already saw it lands straight on the
                // biometric step instead.
                final introSeen = await vault.unlockPreferences.getIntroSeen();
                return introSeen ? '/onboarding/biometric' : '/onboarding';
              }
            }
            return null;
          case VaultState.legacy:
          case VaultState.unreadable:
            if (location == '/' || location.startsWith('/account')) {
              return '/vault/recover';
            }
            return null;
        }
      },
      routes: [
        GoRoute(
          path: '/onboarding',
          name: 'onboarding.intro',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            return OnboardingIntroPage(
              onContinue: () async {
                await vault.unlockPreferences.setIntroSeen(true);
                seenIntro.value = true;
                final supportsBiometric = await vault.authService.isSupported();
                if (!context.mounted) return;
                if (supportsBiometric) {
                  context.goNamed('onboarding.biometric');
                } else {
                  // `onboarding-flow` spec's "Unsupported device skips the
                  // biometric step" scenario -- decided here, at the
                  // composition root, not inside the biometric page itself.
                  context.goNamed('onboarding.pin');
                }
              },
            );
          },
        ),
        GoRoute(
          path: '/onboarding/biometric',
          name: 'onboarding.biometric',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            final controller = BiometricEnrollmentController(
              authService: vault.authService,
              unlockPreferences: vault.unlockPreferences,
            );
            return OnboardingBiometricPage(
              onEnable: () async {
                await controller.enable();
                if (context.mounted) context.goNamed('onboarding.pin');
              },
              // `onboarding-flow` spec's "Skipping the biometric step still
              // proceeds to PIN setup" scenario -- skipping never touches the
              // controller, so nothing is written.
              onSkip: () => context.goNamed('onboarding.pin'),
            );
          },
        ),
        GoRoute(
          path: '/onboarding/pin',
          name: 'onboarding.pin',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            // design.md D3: "Cleared ... on entering /onboarding/pin" --
            // discards any stale PIN from a previous pass through this route
            // (e.g. backing out after an earlier PIN setup) before a new one
            // is entered.
            vault.onboardingDraft.clear();
            return PinSetupPage(
              onPinConfirmed: (pin) async {
                vault.onboardingDraft.setPin(pin);
                // `go`, not `push`: matches this file's existing "go once
                // something is durably decided" convention (see header
                // comment) -- the PIN is now held by the draft, ready for the
                // upcoming seed-commit step.
                if (context.mounted) context.goNamed('home');
              },
            );
          },
        ),
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => SeedSetupChoicePage(
            // `push`, not `go`: nothing has been persisted yet, so the user
            // must be able to freely back out of Generate/Import (see this
            // file's header block comment).
            onGenerate: () => context.pushNamed('generate'),
            onImport: () => context.pushNamed('import'),
          ),
        ),
        GoRoute(
          path: '/generate',
          name: 'generate',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            return SeedGeneratePage(
              controller: SeedGenerateController(
                mnemonicService: vault.mnemonicService,
              ),
              draft: vault.onboardingDraft,
              // `push`: still nothing persisted (see header comment).
              onGenerated: (mnemonic) =>
                  context.pushNamed('generate.show', extra: mnemonic),
            );
          },
        ),
        GoRoute(
          path: '/generate/show',
          name: 'generate.show',
          builder: (context, state) {
            final mnemonic = state.extra as Mnemonic;
            return SeedShowPage(
              mnemonic: mnemonic,
              // `push`: still nothing persisted (see header comment).
              onContinue: () =>
                  context.pushNamed('generate.verify', extra: mnemonic),
            );
          },
        ),
        GoRoute(
          path: '/generate/verify',
          name: 'generate.verify',
          builder: (context, state) {
            final mnemonic = state.extra as Mnemonic;
            final vault = VaultScope.of(context);
            final controller = SeedVerifyController(
              mnemonic: mnemonic,
              vaultCommitService: vault.vaultCommitService,
            );
            return SeedVerifyPage(
              controller: controller,
              // biometric-unlock-onboarding design.md D3: when onboarding
              // already collected a PIN (`OnboardingDraft.hasPin`), commit
              // straight away using it — no second PIN prompt (`onboarding-flow`
              // spec's "Onboarding Credentials Survive To Seed Sealing"
              // requirement). Otherwise (hot-restart draft loss, or a
              // recovery-page re-generate), fall back to the EXISTING
              // `generate.pinSetup` route unchanged (D3's abort/fallback).
              onVerified: () async {
                if (vault.onboardingDraft.hasPin) {
                  await controller.commitWithDraft(vault.onboardingDraft);
                  final error = controller.commitState.errorOrNull;
                  if (error != null) throw StateError(error);
                  await vault.refreshVaultState();
                  // biometric-unlock-onboarding design.md D5: a just-
                  // committed user is never bounced to `/unlock` -- called
                  // AFTER refreshVaultState() so it is never clobbered by
                  // that method's own "reset appUnlocked when not current"
                  // side effect.
                  markUnlocked();
                  if (context.mounted) context.goNamed('account');
                  return;
                }
                if (context.mounted) {
                  context.pushNamed('generate.pinSetup', extra: controller);
                }
              },
            );
          },
        ),
        GoRoute(
          path: '/generate/verify/pin-setup',
          name: 'generate.pinSetup',
          builder: (context, state) {
            final controller = state.extra as SeedVerifyController;
            final vault = VaultScope.of(context);
            return PinSetupPage(
              onPinConfirmed: (pin) async {
                // seed-passphrase-25th-word design.md D3 (task 3.7): this
                // fallback screen only collects a fresh PIN -- a passphrase
                // may already have been opted into and written on
                // SeedGeneratePage, three routes earlier. Forward it
                // unchanged; `takePassphrase()` returns an empty buffer
                // (never null) when nothing was ever set, which
                // commit()/derive() already treat as "no passphrase".
                await controller.commitWithPin(
                  pin,
                  passphraseUtf8: vault.onboardingDraft.takePassphrase(),
                );
                final error = controller.commitState.errorOrNull;
                if (error != null) throw StateError(error);
                await vault.refreshVaultState();
                // biometric-unlock-onboarding design.md D5: called AFTER
                // refreshVaultState() -- see `generate.verify`'s own comment
                // above.
                markUnlocked();
                // `go`, not `push`: the seed was just sealed and written to
                // secure storage — this is the actual commit point now (PR7's
                // cutover), so `go` resets go_router's matched-route stack to
                // just `/account`, discarding the whole
                // Generate -> Show -> Verify -> PIN-setup push stack (see
                // header comment) and making it impossible to navigate back
                // into an already-committed seed-entry flow.
                if (context.mounted) context.goNamed('account');
              },
            );
          },
        ),
        GoRoute(
          path: '/import',
          name: 'import',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            final controller = SeedImportController(
              mnemonicService: vault.mnemonicService,
              vaultCommitService: vault.vaultCommitService,
            );
            return SeedImportPage(
              controller: controller,
              draft: vault.onboardingDraft,
              // Same onboarding-draft-first, existing-pinSetup-fallback logic
              // as `generate.verify` above (design.md D3).
              onImported: () async {
                if (vault.onboardingDraft.hasPin) {
                  await controller.commitWithDraft(vault.onboardingDraft);
                  final error = controller.commitState.errorOrNull;
                  if (error != null) throw StateError(error);
                  await vault.refreshVaultState();
                  // biometric-unlock-onboarding design.md D5: see
                  // `generate.verify`'s own comment above.
                  markUnlocked();
                  if (context.mounted) context.goNamed('account');
                  return;
                }
                if (context.mounted) {
                  context.pushNamed('import.pinSetup', extra: controller);
                }
              },
            );
          },
        ),
        GoRoute(
          path: '/import/pin-setup',
          name: 'import.pinSetup',
          builder: (context, state) {
            final controller = state.extra as SeedImportController;
            final vault = VaultScope.of(context);
            return PinSetupPage(
              onPinConfirmed: (pin) async {
                // Same passphrase-forwarding rationale as
                // `generate.pinSetup` above (task 3.7).
                await controller.commitWithPin(
                  pin,
                  passphraseUtf8: vault.onboardingDraft.takePassphrase(),
                );
                final error = controller.commitState.errorOrNull;
                if (error != null) throw StateError(error);
                await vault.refreshVaultState();
                // biometric-unlock-onboarding design.md D5: see
                // `generate.verify`'s own comment above.
                markUnlocked();
                // `go`: same seed-commit point as `generate.pinSetup` above.
                if (context.mounted) context.goNamed('account');
              },
            );
          },
        ),
        GoRoute(
          path: '/account',
          name: 'account',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            final controller = vault.accountController;
            // One-shot load guard (account-controller-host design.md D4,
            // moved here from `AccountPage`'s deleted `initState`): fires
            // exactly once per builder invocation from `AsyncIdle`/
            // `AsyncError`, never while already `AsyncLoading`/`AsyncData`.
            // `notifyListeners()` alone cannot re-run this builder — only a
            // go_router rebuild (location change or `refreshListenable`
            // firing) does — so this never double-fires from the
            // `ListenableBuilder` inside `AccountPage` reacting to its own
            // controller.
            if (!controller.state.isLoading &&
                controller.state.dataOrNull == null) {
              controller.load();
            }
            return AccountPage(
              controller: controller,
              // `push`: signing hasn't happened yet, so the user must be
              // able to back out of scanning/reviewing (see header comment).
              onScanToSign: () => context.pushNamed('scan'),
              // `push`: nothing is persisted by revealing the mnemonic, so
              // the user can freely back out of the PIN step (see header
              // comment). Gap-closure: `ethereum-account` spec's "Mnemonic
              // still requires a separate gated flow" scenario.
              onRevealSeed: () => context.pushNamed('revealSeedPin'),
              // `push`: opening settings persists nothing by itself (see
              // header comment) -- the user can freely back out.
              onOpenSecuritySettings: () =>
                  context.pushNamed('accountSecurity'),
              // `push`: the confirmation dialog itself deletes nothing, and
              // declining/backing out of the PIN step below deletes nothing
              // either (see header comment) -- both must remain freely
              // reversible until a correct PIN actually commits the wipe.
              onDeleteAccount: () async {
                final confirmed = await showVaultResetConfirmation(context);
                if (confirmed && context.mounted) {
                  context.pushNamed('deleteAccountPin');
                }
              },
            );
          },
        ),
        GoRoute(
          path: '/account/scan',
          name: 'scan',
          builder: (context, state) {
            return ScanPage(
              // A closure, not a live instance: `ControllerHost` inside
              // `ScanPage` invokes this exactly once, at mount — nothing is
              // allocated (in particular no camera handle) until then. This
              // is the fix for a router-rebuild leak: `refreshListenable:
              // vaultState` can rebuild this matched route without unmounting
              // `ScanPage`, and passing a live instance here would construct
              // a SECOND `MobileScannerFrameSource`/`ScanController` on every
              // such rebuild (state-management-foundation design.md's "The
              // /account/scan builder passes factories, not live instances").
              createController: () =>
                  ScanController(frameSource: MobileScannerFrameSource()),
              // `frameSource` is used by both `ScanController` and the
              // camera preview widget, so the preview must be derived from
              // the SAME controller `ControllerHost` created, not built
              // eagerly here. `buildMobileScannerPreview` (design.md D8)
              // pattern-matches the concrete frame source type itself, so
              // this file no longer needs its own `mobile_scanner` import
              // just to construct the preview widget (no `as` cast: an
              // unrecognized type degrades to an empty preview instead of
              // throwing).
              cameraPreviewBuilder: (controller) =>
                  buildMobileScannerPreview(controller.frameSource),
              // `push`: still nothing signed yet (see header comment).
              onComplete: (request) => context.pushNamed(
                'signReview',
                extra: SignRequest.fromEthSignRequest(request),
              ),
            );
          },
        ),
        GoRoute(
          path: '/account/sign',
          name: 'signReview',
          builder: (context, state) {
            final request = state.extra as SignRequest;
            final vault = VaultScope.of(context);
            return SignReviewPage(
              createController: () => SignReviewController(
                request: request,
                signer: vault.transactionSigner,
              ),
              // `push`: nothing is persisted by signing itself (the signed
              // result never touches secure storage), so the user can still
              // navigate back to re-view a just-produced signature (see
              // header comment). Vault-secure-storage-redesign PR7: confirming
              // no longer signs directly — it navigates to the mandatory PIN
              // entry step, see `signPin` below.
              onConfirm: (controller) =>
                  context.pushNamed('signPin', extra: controller),
            );
          },
        ),
        GoRoute(
          path: '/account/sign/pin',
          name: 'signPin',
          builder: (context, state) {
            final controller = state.extra as SignReviewController;
            final vault = VaultScope.of(context);
            return PinEntryPage(
              unlockThrottle: vault.unlockThrottle,
              onSubmit: (pin) async {
                try {
                  await controller.confirmAndSign(pin);
                } on MalformedVaultBlobFailure {
                  // Not a PIN failure — the stored blob itself is unreadable.
                  // Re-probing here flips `vaultState`, and the router's own
                  // `redirect` guard (see this file's `get` factory) takes
                  // over from `refreshListenable`, replacing the whole stack
                  // with `/vault/recover` — no explicit navigation needed.
                  await vault.refreshVaultState();
                  return;
                } on UnsupportedVaultVersionFailure {
                  await vault.refreshVaultState();
                  return;
                }

                final result = controller.state.dataOrNull;
                if (result != null) {
                  if (context.mounted) {
                    context.pushReplacementNamed('signature', extra: result);
                  }
                  return;
                }

                final error = controller.state.errorOrNull;
                if (error != null) throw PinRejectedFailure(error);
              },
            );
          },
        ),
        GoRoute(
          path: '/account/signature',
          name: 'signature',
          // Design.md D6, `qr-air-gapped-signing` spec's "Signature Screen
          // Is Terminal — No Back Navigation" requirement: a deliberate
          // EXCEPTION to this file's "push for every step that hasn't
          // persisted anything yet, so the user can freely back out (...or
          // re-view a just-produced signature)" rule above. Both exits --
          // `SignatureQrPage`'s confirm button AND its intercepted
          // hardware/gesture back -- call the SAME `onDone`, collapsing the
          // scan/review/pin push stack to `/account` in one hop instead of
          // sequential back-navigations.
          builder: (context, state) {
            final result = state.extra as SignedResult;
            return SignatureQrPage(
              signedResult: result,
              onDone: () => context.goNamed('account'),
            );
          },
        ),
        GoRoute(
          path: '/account/reveal-seed/pin',
          name: 'revealSeedPin',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            final controller = RevealSeedController(
              sealedVaultRepository: vault.sealedVaultRepository,
              mnemonicService: vault.mnemonicService,
            );
            return PinEntryPage(
              unlockThrottle: vault.unlockThrottle,
              onSubmit: (pin) async {
                try {
                  await controller.reveal(pin);
                } on MalformedVaultBlobFailure {
                  // Not a PIN failure — same recovery-routing reasoning as
                  // `signPin` above.
                  await vault.refreshVaultState();
                  return;
                } on UnsupportedVaultVersionFailure {
                  await vault.refreshVaultState();
                  return;
                }

                final mnemonic = controller.state.dataOrNull;
                if (mnemonic != null) {
                  if (context.mounted) {
                    context.pushReplacementNamed(
                      'revealSeedShow',
                      extra: mnemonic,
                    );
                  }
                  return;
                }

                final error = controller.state.errorOrNull;
                if (error != null) throw PinRejectedFailure(error);
              },
            );
          },
        ),
        GoRoute(
          path: '/account/reveal-seed/show',
          name: 'revealSeedShow',
          builder: (context, state) {
            final mnemonic = state.extra as Mnemonic;
            return RevealSeedShowPage(
              mnemonic: mnemonic,
              // `pop`, not `go`: this route replaced `revealSeedPin` on the
              // push stack (see `pushReplacementNamed` above), so the stack
              // is `account -> revealSeedShow` — popping returns to Account.
              // Nothing is persisted by revealing the mnemonic, so this stays
              // reversible, matching this file's `push` convention.
              onDone: () => context.pop(),
            );
          },
        ),
        GoRoute(
          path: '/account/delete/pin',
          name: 'deleteAccountPin',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            final controller = VaultResetController(
              sealedVaultRepository: vault.sealedVaultRepository,
              unlockThrottle: vault.unlockThrottle,
              vaultWiper: vault.vaultWiper,
            );
            return PinEntryPage(
              unlockThrottle: vault.unlockThrottle,
              onSubmit: (pin) async {
                try {
                  await controller.confirmReset(pin);
                } on MalformedVaultBlobFailure {
                  // Not a PIN failure -- same recovery-routing reasoning as
                  // `signPin`/`revealSeedPin` above.
                  await vault.refreshVaultState();
                  return;
                } on UnsupportedVaultVersionFailure {
                  await vault.refreshVaultState();
                  return;
                }

                if (controller.wasReset) {
                  // Full wipe succeeded -- refresh so the redirect guard
                  // (VaultState.none/legacy -> '/') takes the app to
                  // onboarding. No separate "device is clean" confirmation
                  // screen (account-deletion spec's "Successful Deletion
                  // Redirects Silently To Onboarding" requirement).
                  await vault.refreshVaultState();
                  return;
                }

                final error = controller.state.errorOrNull;
                if (error != null) throw PinRejectedFailure(error);
              },
            );
          },
        ),
        GoRoute(
          path: '/account/security',
          name: 'accountSecurity',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            return SecuritySettingsPage(
              createController: () => BiometricEnrollmentController(
                authService: vault.authService,
                unlockPreferences: vault.unlockPreferences,
              ),
            );
          },
        ),
        GoRoute(
          path: '/vault/recover',
          name: 'vaultRecover',
          builder: (context, state) => RecoveryPage(
            // Neither of these can escape [VaultState.legacy] in this PR (see
            // `recovery_page.dart`'s own doc comment) — they still push into
            // the ordinary onboarding flows so the screen is not a functional
            // dead end.
            onReImport: () => context.pushNamed('import'),
            onGenerateNew: () => context.pushNamed('generate'),
          ),
        ),
        GoRoute(
          path: '/unlock',
          name: 'unlock',
          builder: (context, state) {
            final vault = VaultScope.of(context);
            return AppUnlockPage(
              createController: () => AppUnlockController(
                authService: vault.authService,
                unlockPreferences: vault.unlockPreferences,
                sealedVaultRepository: vault.sealedVaultRepository,
                unlockThrottle: vault.unlockThrottle,
              ),
              onUnlocked: markUnlocked,
              // Same recovery-routing reasoning as `signPin`/`revealSeedPin`/
              // `deleteAccountPin` above.
              onVaultUnreadable: vault.refreshVaultState,
            );
          },
        ),
      ],
    );
  }
}
