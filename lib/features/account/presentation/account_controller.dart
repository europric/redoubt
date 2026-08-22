import 'package:flutter/foundation.dart';
import 'package:redoubt/core/bip39/bip39.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

import '../domain/account_derivation_service.dart';
import '../domain/eth_account.dart';
import '../domain/public_account_cache.dart';

/// The bundle `AccountController.state` wraps: the checksummed account
/// address plus the public-only pairing key material, produced by EITHER a
/// cache read ([AccountController.load]) or a derive-and-write
/// ([AccountController.repairCache]) — the type itself does not distinguish
/// which produced it (account-controller-host design.md D1: "provenance-
/// neutral").
///
/// Carries **zero** secret material: [account] is a checksummed public
/// address, and [pairingKey] is structurally public-only (no entropy/
/// mnemonic/private-key field, no constructor path to one). Deliberately
/// declares no `==`/`hashCode`/`toString()` — nothing compares or prints
/// this bundle, and identity equality keeps `AsyncState`'s no-value-equality
/// invariant uniform (design.md D1's "Secret-material statement").
class AccountDetails {
  const AccountDetails({required this.account, required this.pairingKey});

  final EthAccount account;
  final AccountPairingKey pairingKey;
}

/// Owns the Account screen's load step (route `/account`).
///
/// **`load()` reads ONLY [accountCache]** (vault-secure-storage-redesign
/// PR2, `ethereum-account` spec's "Address Display Without Re-Exposing
/// Seed" requirement: "AccountController.load() MUST NOT touch
/// vault/KEK/derivation"). It never calls [seedRepository] or
/// [derivationService] — those exist on this controller solely for
/// [repairCache], the explicit, non-`load()`-path method that re-derives
/// and re-populates the cache (e.g. after a real seed-commit, or as a
/// user-triggered "Unlock to restore account details" lazy repair per
/// design.md's "Cache rewrite triggers" list).
class AccountController extends ChangeNotifier {
  AccountController({
    required this.seedRepository,
    required this.derivationService,
    required this.accountCache,
  });

  final SecureSeedRepository seedRepository;
  final AccountDerivationService derivationService;
  final PublicAccountCache accountCache;

  AsyncState<AccountDetails> _state = const AsyncIdle<AccountDetails>();
  AsyncState<AccountDetails> get state => _state;

  /// Reads [accountCache] and populates [state] with an [AsyncData] from
  /// it. Never touches [seedRepository] or [derivationService] — no
  /// unlock, no BIP-32 derivation, ever, on this path. If the cache is
  /// empty (no vault has ever been committed), lands [state] in
  /// [AsyncError] instead.
  ///
  /// **Every path terminates in [AsyncData] or [AsyncError]** — account-
  /// controller-host design.md D2: a thrown [accountCache] failure is
  /// caught and demoted to [AsyncError] rather than leaving [state] stuck
  /// at [AsyncLoading] forever (the bug this change fixes; a stuck loading
  /// state under the `/account` route's `!isLoading` guard would also
  /// permanently block retry-on-revisit).
  Future<void> load() async {
    _state = const AsyncLoading<AccountDetails>();
    notifyListeners();

    try {
      final cached = await accountCache.read();
      if (cached == null) {
        _state = const AsyncError<AccountDetails>('No vault found.');
        return;
      }

      _state = AsyncData<AccountDetails>(
        AccountDetails(account: cached.account, pairingKey: cached.pairing),
      );
    } catch (_) {
      _state = const AsyncError<AccountDetails>(
        'Unable to load account details.',
      );
    } finally {
      notifyListeners();
    }
  }

  /// Explicit, user-triggered repair path (NEVER called from [load] or any
  /// implicit trigger — `public-account-cache` spec's "Cache Repair Is An
  /// Explicit User-Triggered Path" requirement): reads the entropy from
  /// [seedRepository], re-derives via [derivationService], writes the
  /// result back to [accountCache], and lands [state] in [AsyncData]. If no
  /// entropy is stored, or any dependency throws (e.g. a biometric
  /// cancel/failure from [seedRepository.readEntropy]), lands [state] in
  /// [AsyncError] instead and leaves the cache untouched.
  ///
  /// **No second in-flight flag** (design.md D5): reuses the same
  /// [AsyncLoading] state [load] uses. Since the repair affordance only
  /// exists in the [AsyncError] arm, at most one of [load]/[repairCache] is
  /// ever in flight at a time.
  Future<void> repairCache() async {
    _state = const AsyncLoading<AccountDetails>();
    notifyListeners();

    try {
      final entropy = await seedRepository.readEntropy();
      if (entropy == null) {
        _state = const AsyncError<AccountDetails>('No vault found.');
        return;
      }

      // `seedRepository` here is the legacy, out-of-scope
      // `SecureSeedRepository` (confirmed unaffected by this change — see
      // tasks.md's "Out-of-Scope, Verified" note): it carries opaque
      // entropy bytes only, never a language marker, so this repair path
      // hardcodes English — matching this repository's pre-existing,
      // English-only behavior byte-for-byte.
      final derived = await derivationService.derive(
        entropy,
        language: MnemonicLanguage.english,
      );
      await accountCache.write(
        account: derived.account,
        derivationPath: kAccountDerivationPath,
        pairing: derived.pairingKey,
      );
      _state = AsyncData<AccountDetails>(
        AccountDetails(
          account: derived.account,
          pairingKey: derived.pairingKey,
        ),
      );
    } catch (_) {
      _state = const AsyncError<AccountDetails>(
        'Unable to restore account details.',
      );
    } finally {
      notifyListeners();
    }
  }

  /// Clears any previously loaded [state] back to [AsyncIdle].
  ///
  /// Called by [VaultScope.refreshHasSeed] whenever the seed changes
  /// (generate/import success, or vault reset/delete) so the NEXT visit to
  /// the Account screen re-derives fresh data instead of showing
  /// stale/previous-seed data — this is what makes the controller safe to
  /// keep as a long-lived singleton rather than reconstructing it per
  /// navigation.
  void reset() {
    _state = const AsyncIdle<AccountDetails>();
    notifyListeners();
  }
}
