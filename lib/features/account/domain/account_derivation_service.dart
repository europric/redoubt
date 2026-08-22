import 'dart:typed_data';

import 'package:redoubt/core/bip39/bip39.dart';

import 'eth_account.dart';

/// The single, fixed BIP-32 path this vault ever derives its signing
/// account at (`m/44'/60'/0'/0/0`) — `ethereum-account` spec's "Single
/// Fixed-Path Derivation" requirement. Shared by [PublicAccountCache] (the
/// value it stores alongside the address) and `VaultCommitService` (the
/// value it writes), so both always agree on the same literal.
const kAccountDerivationPath = "m/44'/60'/0'/0/0";

/// Public-only key material for the account-level (`m/44'/60'/0'`) pairing
/// extended public key.
///
/// **Structural guarantee** (design.md's "the type signature of whatever
/// builds this QR should make it structurally impossible to pass a private
/// key/mnemonic in"): every field here is derivable-from-a-public-key data
/// — a compressed public key, a chain code, and BIP-32 path/fingerprint
/// metadata. There is no entropy/mnemonic/private-key field on this type
/// and no constructor path that could populate one, so any function that
/// accepts an [AccountPairingKey] (e.g. `pairing_qr.dart`'s
/// `buildPairingQrUrString`) cannot be handed a seed even by mistake — the
/// parameter type itself rules it out.
class AccountPairingKey {
  const AccountPairingKey({
    required this.publicKeyCompressed,
    required this.chainCode,
    required this.sourceFingerprint,
    required this.parentFingerprint,
    required this.depth,
    required this.pathIndexes,
  });

  /// The 33-byte SEC1-compressed public key at `m/44'/60'/0'`.
  final List<int> publicKeyCompressed;

  /// The 32-byte BIP-32 chain code for the same key.
  final List<int> chainCode;

  /// Fingerprint (first 4 bytes of `hash160(pubkey)`) of the master key
  /// this path was derived from.
  final int sourceFingerprint;

  /// Fingerprint of this key's immediate parent (`m/44'/60'`).
  final int parentFingerprint;

  /// BIP-32 depth of this key (`3` for `m/44'/60'/0'`).
  final int depth;

  /// The hardened path components in order: `[44, 60, 0]`.
  final List<int> pathIndexes;
}

/// The bundle a single [AccountDerivationService.derive] call returns:
/// the signing account's address plus the public-only pairing key
/// material, both derived from one shared BIP-39 seed derivation
/// (design.md's derivation-service API redesign).
class DerivedAccount {
  const DerivedAccount({required this.account, required this.pairingKey});

  final EthAccount account;
  final AccountPairingKey pairingKey;

  @override
  String toString() => 'DerivedAccount($account, $pairingKey)';
}

/// The fakeable boundary over BIP-32/44 Ethereum key derivation.
///
/// [derive] takes only [entropy] (the same value `core/security`'s
/// `SecureSeedRepository` persists) — there is no account-index,
/// address-index, or path parameter anywhere on this interface, so no
/// caller can request any account or path other than the one fixed
/// derivation this vault supports (`ethereum-account` spec's "Single
/// Fixed-Path Derivation" requirement, "No multi-account affordance"
/// scenario).
abstract interface class AccountDerivationService {
  /// Derives both the single fixed-path signing account
  /// (`m/44'/60'/0'/0/0`) and the public-only pairing key
  /// (`m/44'/60'/0'`) from one shared BIP-39 seed derivation.
  ///
  /// [passphraseUtf8] is the optional BIP-39 passphrase ("25th word",
  /// seed-passphrase-25th-word design.md D1), UTF-8-encoded. `null` or
  /// empty means no passphrase — byte-identical to this method's
  /// pre-passphrase derivation. A different non-empty [passphraseUtf8]
  /// deterministically derives a different account from the SAME
  /// [entropy] (`ethereum-account` spec's "Different passphrases derive
  /// different addresses").
  ///
  /// **No cross-call caching**: implementations MUST NOT retain the
  /// derived seed (or any other secret) between calls — each call
  /// recomputes from [entropy] (and [passphraseUtf8]) alone, so passing
  /// different entropy on a later call never observes a stale result from
  /// a previous one (design.md's "Retire the entropy-keyed seed cache
  /// instead of porting it" decision).
  ///
  /// `Future`-returning because the underlying BIP-39 seed derivation
  /// (PBKDF2-HMAC-SHA512, 2048 rounds) runs on a background isolate rather
  /// than blocking the caller's isolate — see
  /// `core/eth/bip39_seed.dart`'s doc comment for why.
  ///
  /// [language] selects which wordlist [entropy] is re-encoded against —
  /// REQUIRED, never defaulted (bip39-nfkd-normalization design.md's
  /// "Make the language a required parameter, never a defaulted one, at
  /// every derivation site" decision): a default here would silently
  /// re-derive a non-English vault's addresses as English, a fund-affecting
  /// bug.
  Future<DerivedAccount> derive(
    Uint8List entropy, {
    required MnemonicLanguage language,
    Uint8List? passphraseUtf8,
  });
}
