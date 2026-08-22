/// [AccountDerivationService] backed by `blockchain_utils`'s BIP-32/44
/// implementation (the locked crypto-stack decision, design.md's
/// "Ethereum crypto stack" section — already a dependency since PR2/PR4).
///
/// Derivation chain, per BIP-44 for coin type 60 (Ethereum):
///
///     entropy ──(Bip39MnemonicEncoder)──> mnemonic
///             ──(Bip39SeedGenerator, empty passphrase)──> 64-byte seed
///             ──(Bip32, m/44'/60'/0')──> pairing account-level key (public)
///             ──(m/44'/60'/0'/0/0)──> signing account key (address)
///
/// Every private key material stays inside `blockchain_utils`'s own
/// `Bip44`/`Bip32` objects for the lifetime of a single [derive] call and
/// is never returned to a caller — [derive] returns only a checksummed
/// address string and public key/chain-code bytes (see
/// [AccountPairingKey]'s own doc comment for the structural guarantee this
/// provides to the pairing QR).
///
/// **No cross-call seed cache** (vault-secure-storage-redesign, design.md's
/// "Retire the entropy-keyed seed cache instead of porting it" decision):
/// a prior revision of this class cached the 64-byte BIP-39 master seed in
/// a `_cachedSeed`/`_cachedEntropyHex` singleton keyed by the entropy hex
/// string, retaining that secret in RAM for the whole process lifetime.
/// Under the `Uint8List` migration that key would break anyway
/// (`Uint8List.==` is identity, not value equality), and the cache was a
/// real exposure the redesign deliberately does not carry forward. The
/// cache's original purpose — killing 3x redundant PBKDF2 per
/// Account-screen visit — is now served instead by [derive] computing the
/// seed exactly ONCE per call and deriving both outputs from it, combined
/// with the public account cache (Phase 3) making the Account screen's
/// display path derive zero times at all.
library;

import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart' hide Mnemonic;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:redoubt/core/bip39/bip39.dart';
import 'package:redoubt/core/eth/eth.dart';

import '../domain/account_derivation_service.dart';
import '../domain/eth_account.dart';

class Bip32AccountDerivationService implements AccountDerivationService {
  Bip32AccountDerivationService({
    @visibleForTesting Bip39SeedDeriver? seedFromEntropy,
  }) : _seedFromEntropy = seedFromEntropy ?? deriveBip39SeedInBackground;

  final Bip39SeedDeriver _seedFromEntropy;

  @override
  Future<DerivedAccount> derive(
    Uint8List entropy, {
    required MnemonicLanguage language,
    Uint8List? passphraseUtf8,
  }) async {
    final seed = await _seedFromEntropy(
      entropy,
      language: language,
      passphraseUtf8: passphraseUtf8,
    );
    final masterKey = Bip44.fromSeed(seed, Bip44Coins.ethereum);

    // `m/44'/60'/0'` — the pairing account-level key (public-derivable).
    final accountKey = masterKey.purpose.coin.account(0);

    // `m/44'/60'/0'/0/0` — the single fixed signing account this vault
    // ever uses (`ethereum-account` spec's "Single Fixed-Path Derivation").
    final addressKey = accountKey.change(Bip44Changes.chainExt).addressIndex(0);

    final address = EthAddrEncoder().encodeKey(
      addressKey.bip32.publicKey.compressed,
    );

    final pubKey = accountKey.bip32.publicKey;
    final pairingKey = AccountPairingKey(
      publicKeyCompressed: List<int>.unmodifiable(pubKey.compressed),
      chainCode: List<int>.unmodifiable(pubKey.chainCode.toBytes()),
      // `m` — the master key, used only to compute the pairing QR's
      // `source-fingerprint` (BCR-2020-007's
      // `crypto-keypath.source-fingerprint` is the fingerprint of the ROOT
      // key a path was derived from, distinct from the derived key's own
      // immediate-parent fingerprint).
      sourceFingerprint: _fingerprintToInt(
        masterKey.bip32.publicKey.fingerPrint.toBytes(),
      ),
      parentFingerprint: _fingerprintToInt(
        accountKey.bip32.parentFingerPrint.toBytes(),
      ),
      depth: accountKey.bip32.depth.toInt(),
      pathIndexes: const [44, 60, 0],
    );

    return DerivedAccount(
      account: EthAccount(address: address),
      pairingKey: pairingKey,
    );
  }

  int _fingerprintToInt(List<int> fingerprintBytes) =>
      IntUtils.fromBytes(fingerprintBytes, byteOrder: Endian.big);
}
