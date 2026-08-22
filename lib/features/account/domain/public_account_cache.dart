/// Unlock-free cache of the vault's public account data — the derived ETH
/// [EthAccount.address], its fixed derivation path, and the
/// [AccountPairingKey] material — written once at seed-commit time so the
/// Account screen (and the pairing QR it renders) never needs to touch the
/// vault or re-derive anything (`public-account-cache` spec's "Cache Read
/// Requires No Unlock And No Derivation" requirement).
///
/// **hexagonal-architecture-refactor PR2**: this port moved from
/// `lib/core/security/public_account_cache.dart` to `features/account/
/// domain/` (proposal.md decision 1) — `core/security` importing a
/// `features/account` type was an inverted dependency the refactor's
/// `architecture-boundaries` spec forbids. The interface, [CachedAccount],
/// and their documented behavior are unchanged; only the file's location
/// and package moved. The real implementation, [FlutterPublicAccountCache],
/// now lives at `features/account/data/flutter_public_account_cache.dart`.
///
/// **Design decision (design.md's "Public account cache lives in
/// `flutter_secure_storage` under its own key, read undecorated")**: this
/// is a STRICTLY-STRONGER deviation from the proposal's "unencrypted"
/// wording, not a weaker one. The requirement is *unlock-free*, not
/// *deliberately plaintext* — `flutter_secure_storage` reads cost only a
/// few ms and never prompt for biometrics/PIN, so the implementation uses
/// the same underlying OS keystore/keychain as
/// `FlutterSecureSeedRepository` but under its own key
/// (`vault.account.public.v1`, distinct from `vault.seed.entropy`) and
/// WITHOUT the `AuthenticatedSeedRepository` decorator — there is no auth
/// gate anywhere in that implementation, by construction: it has no
/// dependency on `auth_service.dart` at all.
///
/// **Cache Contains Only Public Data** (`public-account-cache` spec):
/// [PublicAccountCache.write] accepts only an [EthAccount] (checksummed
/// address), a derivation path string, and an [AccountPairingKey] (public-
/// key-only — see that type's own doc comment for why it is structurally
/// impossible to pass it a private key). There is no
/// entropy/mnemonic/private-key shaped parameter anywhere on this
/// interface.
library;

import 'account_derivation_service.dart';
import 'eth_account.dart';

/// The bundle [PublicAccountCache.read] returns: exactly what was written
/// by the most recent [PublicAccountCache.write] call.
class CachedAccount {
  const CachedAccount({
    required this.account,
    required this.derivationPath,
    required this.pairing,
  });

  final EthAccount account;
  final String derivationPath;
  final AccountPairingKey pairing;
}

/// The fakeable boundary over the unlock-free public account cache.
abstract interface class PublicAccountCache {
  /// Persists [account]/[derivationPath]/[pairing] as the vault's cached
  /// public account data. Overwrites any previously cached value.
  Future<void> write({
    required EthAccount account,
    required String derivationPath,
    required AccountPairingKey pairing,
  });

  /// Reads the cached account data, or `null` if nothing has been written
  /// yet (`public-account-cache` spec's "Empty Cache Routes Straight To
  /// Onboarding" requirement treats `null` as "no vault yet").
  Future<CachedAccount?> read();

  /// Explicit clear, called on vault reset (`public-account-cache` spec's
  /// "Cache Written Once At Seed-Commit Time" requirement: "Vault reset
  /// clears the cache").
  Future<void> clear();
}
