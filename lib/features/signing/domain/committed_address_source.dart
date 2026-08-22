/// A narrow, `signing`-owned seam onto the commit-time committed address —
/// exactly what [EthTransactionSigner]'s D5 address-match guard needs, and
/// nothing more.
///
/// **hexagonal-architecture-refactor PR4 (design.md D6)**: `signing/data`
/// previously depended on `account/domain/public_account_cache.dart`'s full
/// [PublicAccountCache] interface (write/read/clear of a [CachedAccount])
/// just to read one address string — a cross-feature `domain/`→`domain/`
/// import the refactor's `architecture-boundaries` spec forbids outside
/// `lib/config/**`. This port replaces that field: `signing/domain` defines
/// only the shape it actually consumes, and the composition root
/// (`lib/config/adapters/cached_account_address_source.dart`) binds it to
/// the real [PublicAccountCache] without `signing` ever importing
/// `account`'s domain layer directly.
library;

/// The fakeable boundary [EthTransactionSigner] uses for its commit-time
/// address-match guard (design.md D5).
abstract interface class CommittedAddressSource {
  /// The checksummed ETH address committed at seed-commit time, or `null`
  /// if nothing has been committed yet (mirrors [PublicAccountCache.read]
  /// returning `null` for an empty cache).
  Future<String?> committedAddress();
}
