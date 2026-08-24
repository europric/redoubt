/// [TransactionSigner] backed by `blockchain_utils`'s BIP-32/44 (the same
/// locked crypto-stack decision `account/data/bip32_account_derivation_service.dart`
/// uses) + `core/eth/signing.dart`'s secp256k1 signer.
///
/// **Full PIN-unlock flow (vault-secure-storage-redesign PR7, task 8.5b)**:
/// supersedes the pre-PR7 version, which read the legacy plaintext-hex
/// entropy through the biometric-gated `AuthenticatedSeedRepository`. This
/// class now orchestrates the ENTIRE unlock-for-signing sequence itself
/// (design.md's "Signing" data-flow diagram):
/// ```
/// readBlob() -> header pre-check (uncharged Malformed/UnsupportedVersion)
///   -> unlockThrottle.recordAttemptStart() -> authService.authenticate()
///   (skipped if isSupported() is false) -> VaultCipher.open() [compute
///   isolate] -> unlockThrottle.recordSuccess() -> derive privKey -> sign
///   -> zeroize everything
/// ```
///
/// **Wrong PIN vs corrupt blob are different failures** (design.md
/// decision): [sign] parses the blob's HEADER ONLY (cheap, no KDF) via
/// [VaultBlob.decodeBytes] BEFORE ever calling
/// [UnlockThrottle.recordAttemptStart] — a structurally broken or
/// unknown-version blob throws directly from that pre-check and never
/// charges the throttle. Only once the header is known-parseable does
/// [UnlockThrottle.recordAttemptStart] run, immediately before the real
/// (KDF-costing) [openVaultBlobInBackground] call — so a [WrongPinFailure]
/// from that call has already been charged, matching design.md's "wrong PIN
/// charges the throttle" rule.
///
/// **Structural guarantee (design.md's Secure Storage Design diagram)**:
/// both the sealed blob's decrypted entropy and the derived signing private
/// key are held only in local variables for the duration of this single
/// method call — never stored on `this`, never returned to a caller — and
/// are zero-filled in a `finally` block before the method returns (success
/// OR failure/exception), so no copy of either survives past this call.
library;

import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart' hide Mnemonic;
import 'package:redoubt/core/bip39/bip39.dart';
import 'package:redoubt/core/eth/eth.dart';
import 'package:redoubt/core/security/security.dart';
import 'package:redoubt/core/ur/ur_api.dart';

import '../domain/committed_address_source.dart';
import '../domain/sign_request.dart';
import '../domain/signed_result.dart';
import '../domain/transaction_signer.dart';

class EthTransactionSigner implements TransactionSigner {
  EthTransactionSigner({
    required this.sealedVaultRepository,
    required this.unlockThrottle,
    required this.authService,
    required this.committedAddressSource,
  });

  final SealedVaultRepository sealedVaultRepository;
  final UnlockThrottle unlockThrottle;
  final AuthService authService;

  /// The commit-time committed address this vault's address is checked
  /// against on every sign (design.md D5 — required, not nullable: "a
  /// nullable seam lets a fake silently disable the guard").
  ///
  /// **hexagonal-architecture-refactor PR4 (design.md D6)**: narrowed from
  /// the full `PublicAccountCache` port to this feature-owned
  /// [CommittedAddressSource] seam — `signing/data` no longer imports
  /// `account/domain` directly; the composition root binds this to the real
  /// cache via `CachedAccountAddressSource`.
  final CommittedAddressSource committedAddressSource;

  @override
  Future<SignedResult?> sign(
    SignRequest request, {
    required Uint8List pin,
    Uint8List? passphraseUtf8,
  }) async {
    final blob = await sealedVaultRepository.readBlob();
    if (blob == null) {
      // No vault exists at all — the router's VaultState guard should
      // already prevent reaching this screen in that state, but this stays
      // a safe no-op rather than a crash.
      return null;
    }

    // Cheap header-only pre-check, no KDF: throws MalformedVaultBlobFailure/
    // UnsupportedVaultVersionFailure directly (propagated to the caller)
    // WITHOUT ever calling recordAttemptStart() — see this class's own doc
    // comment on why this ordering matters.
    VaultBlob.decodeBytes(blob);

    await unlockThrottle.recordAttemptStart();

    if (await authService.isSupported()) {
      final authenticated = await authService.authenticate();
      if (!authenticated) {
        // Denied, cancelled, or failed — never touch the KDF. The throttle
        // charge from recordAttemptStart() above stands (a real attempt
        // was requested and denied), matching this class's pre-PR7 "auth
        // denied -> null" convention.
        return null;
      }
    }

    VaultSecret? secret;
    Uint8List? privateKeyBytes;
    try {
      secret = await openVaultBlobInBackground(blob: blob, pin: pin);
      await unlockThrottle.recordSuccess();

      // D8 guard — placed AFTER recordSuccess() (the PIN was genuinely
      // correct — never re-charge the throttle for a language this build
      // cannot honor) and BEFORE any key material is derived: throws with
      // no signature produced and no private key ever materialized,
      // rather than silently signing against a substituted-English
      // re-derivation of a non-English vault (the wrong-wallet bug this
      // whole change exists to prevent).
      final language = secret.requireLanguage();

      final addressKey = await _addressLevelKey(
        secret.entropy,
        language: language,
        passphraseUtf8: passphraseUtf8,
      );

      // D5 — address-match guard, unconditional (runs whether or not a
      // passphrase was supplied: the dangerous case is a passphrase-
      // protected vault whose owner forgot to enable the toggle). Reuses
      // the node just derived above — no second PBKDF2, only a public-key
      // encode. Placed AFTER recordSuccess() (the PIN was correct — never
      // charge the throttle for a passphrase typo) and BEFORE
      // privateKeyBytes is materialized, so a mismatch never puts a
      // wrong-key private scalar in memory.
      final derivedAddress = EthAddrEncoder().encodeKey(
        addressKey.bip32.publicKey.compressed,
      );
      final committed = await committedAddressSource.committedAddress();
      // `committed == null` now fails closed: the `public-account-cache`
      // spec's "Empty Cache Routes Straight To Onboarding" still generally
      // prevents reaching a sign screen without a committed address, but an
      // empty cache is reachable through e.g. a stale session or a race, and
      // failing open here would silently sign with the wrong (uncommitted)
      // key — the most dangerous possible failure mode. See the D5 ADR for
      // the full risk analysis.
      if (committed == null ||
          committed.toLowerCase() != derivedAddress.toLowerCase()) {
        throw const PassphraseMismatchFailure();
      }

      privateKeyBytes = Uint8List.fromList(addressKey.bip32.privateKey.raw);

      final hash = keccak256(request.signData);
      final signature = signHash(privateKeyBytes, hash);
      final chainId = request.chainId;
      // Typed transactions (EIP-2930/EIP-1559, EthSignDataType.typedTransaction)
      // already carry chainId inside their own RLP envelope (EIP-2718), so
      // their signature's `v` component is the plain y-parity/recoveryId (0
      // or 1) per the typed-transaction spec — NOT the legacy EIP-155
      // `recoveryId + chainId*2 + 35` encoding, which only applies to
      // untyped (dataType=transaction) transactions. Applying eip155V here
      // unconditionally produced a nonsensical v (e.g. 147/148 for
      // chainId=56), which MetaMask/viem reject as "y-parity should be 0 or
      // 1".
      final v = request.dataType == EthSignDataType.typedTransaction
          ? signature.recoveryId
          : chainId != null
          ? eip155V(signature.recoveryId, chainId)
          : 27 + signature.recoveryId;

      final signatureBytes = Uint8List.fromList([
        ..._bigIntTo32Bytes(signature.r),
        ..._bigIntTo32Bytes(signature.s),
        v,
      ]);

      return SignedResult(
        signature: signatureBytes,
        requestId: request.requestId,
        origin: request.origin,
      );
    } finally {
      secret?.zeroize();
      if (privateKeyBytes != null) {
        privateKeyBytes.fillRange(0, privateKeyBytes.length, 0);
      }
      if (passphraseUtf8 != null) {
        passphraseUtf8.fillRange(0, passphraseUtf8.length, 0);
      }
    }
  }

  /// `m/44'/60'/0'/0/0` — the single fixed signing account this vault ever
  /// uses, matching `Bip32AccountDerivationService._addressLevelKey`
  /// (`ethereum-account` spec's "Single Fixed-Path Derivation"). Whatever
  /// derivation path a scanned `eth-sign-request` claims is intentionally
  /// ignored — this vault only ever has one signing key, so honoring an
  /// alternate requested path is not meaningful and not implemented.
  ///
  /// [passphraseUtf8] is the optional BIP-39 passphrase ("25th word",
  /// seed-passphrase-25th-word design.md D1) — `null`/empty derives
  /// byte-identically to this method's pre-passphrase behavior.
  ///
  /// [language] is read from the opened vault's [VaultSecret] (D8/D9) —
  /// never supplied by the UI, never defaulted here.
  Future<Bip44> _addressLevelKey(
    Uint8List entropy, {
    required MnemonicLanguage language,
    Uint8List? passphraseUtf8,
  }) async {
    final seed = await deriveBip39SeedInBackground(
      entropy,
      language: language,
      passphraseUtf8: passphraseUtf8,
    );
    final master = Bip44.fromSeed(seed, Bip44Coins.ethereum);
    return master.purpose.coin
        .account(0)
        .change(Bip44Changes.chainExt)
        .addressIndex(0);
  }
}

Uint8List _bigIntTo32Bytes(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length < 64) hex = hex.padLeft(64, '0');
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
