/// The single, fixed-path Ethereum account this vault ever derives
/// (`m/44'/60'/0'/0/0` — `ethereum-account` spec's "Single Fixed-Path
/// Derivation" requirement).
///
/// Deliberately carries only the checksummed public [address] — never a
/// private key, public key, or any derivation metadata — since this is the
/// value shown on `AccountPage` and the spec's "Address Display Without
/// Re-Exposing Seed" requirement means this screen has nothing else to
/// show.
class EthAccount {
  const EthAccount({required this.address});

  /// The EIP-55 checksummed `0x`-prefixed Ethereum address.
  final String address;

  @override
  bool operator ==(Object other) =>
      other is EthAccount && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'EthAccount($address)';
}
