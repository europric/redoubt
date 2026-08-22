import 'package:redoubt/features/account/account.dart';
import 'package:redoubt/features/signing/signing.dart';

/// Composition-root adapter (hexagonal-architecture-refactor PR4,
/// design.md D6): binds `signing`'s narrow [CommittedAddressSource] port to
/// the real [PublicAccountCache], so `signing/data` never imports
/// `account/domain` directly.
class CachedAccountAddressSource implements CommittedAddressSource {
  const CachedAccountAddressSource(this.accountCache);

  /// Exposed (not private) so wiring tests can assert this adapter reads
  /// through the SAME [PublicAccountCache] instance the rest of the
  /// composition root shares — mirrors the identity check
  /// `vault_scope_test.dart` already performed pre-PR4 directly against the
  /// signer's (then-)`publicAccountCache` field.
  final PublicAccountCache accountCache;

  @override
  Future<String?> committedAddress() async {
    final cached = await accountCache.read();
    return cached?.account.address;
  }
}
