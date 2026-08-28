/// The fakeable boundary over transient key derivation + signing
/// (design.md's "signing" feature layering: domain `TransactionSigner`,
/// data `EthTransactionSigner`).
library;

import 'dart:typed_data';

import 'package:redoubt/core/ur/ur_api.dart';

import 'sign_request.dart';
import 'signed_result.dart';

abstract interface class TransactionSigner {
  /// Signs [request] using a key transiently derived for the duration of
  /// this call only (`secure-seed-storage` spec: never persisted, zero-
  /// filled after use — see `EthTransactionSigner`'s own doc comment for
  /// the structural guarantee).
  ///
  /// [pin] unlocks the vault's Argon2id-sealed blob (`vault-unlock` spec's
  /// mandatory PIN requirement, vault-secure-storage-redesign PR7) — the
  /// hardware wrap (biometric/passcode), when available, is layered on top
  /// as an additional factor inside this call, never a substitute for it.
  ///
  /// [passphraseUtf8] is the optional BIP-39 passphrase ("25th word",
  /// seed-passphrase-25th-word design.md D1), UTF-8-encoded. `null` or
  /// empty means no passphrase — byte-identical to this method's
  /// pre-passphrase behavior. Re-supplied fresh at every sign (never stored
  /// or cached) and zeroized by the implementation once signing completes.
  ///
  /// Returns `null` if hardware-wrap authentication was denied, cancelled,
  /// or failed, or if no vault exists — mirroring the pre-PR7
  /// `SecureSeedRepository.readEntropy()` null-on-denied contract so callers
  /// never need a try/catch to distinguish "user said no" from a
  /// programming error.
  ///
  /// Throws `WrongPinFailure` (`vault_cipher.dart`) if [pin] does not open
  /// the stored blob — the unlock throttle IS charged for this. Throws
  /// `MalformedVaultBlobFailure`/`UnsupportedVaultVersionFailure`
  /// (`vault_blob.dart`) if the stored blob itself is unreadable — the
  /// unlock throttle is NOT charged for either (design.md's "Wrong PIN and
  /// corrupt blob are different failures" decision); callers should route
  /// to the vault recovery flow instead of offering a retry. Throws
  /// [PassphraseMismatchFailure] if the freshly-derived address does not
  /// match the vault's commit-time address (design.md D5) — also thrown
  /// when [CommittedAddressSource.committedAddress] returns `null` (the
  /// cache is empty, meaning no address was ever committed; signing with
  /// the uncommitted key would be a silent wrong-wallet bug). The unlock
  /// throttle is NOT charged (the PIN was correct; `recordSuccess()` has
  /// already run), and no signature is produced.
  ///
  /// Throws [UnsupportedSignRequestFailure] for [SignRequest.dataType]s
  /// this vault cannot yet correctly decode/digest (`typedData`,
  /// `personalMessage` — GitHub #28,
  /// `redoubt-critical-fix-round3` design.md D1/D4). This is a
  /// crypto-boundary guard, independent of any UI-level block: it fires
  /// before the vault blob is even unsealed, before [unlockThrottle] is
  /// charged, and before [AuthService.isSupported] is ever called — so a
  /// UI bypass can never reach key derivation for a request type this
  /// vault cannot safely sign.
  Future<SignedResult?> sign(
    SignRequest request, {
    required Uint8List pin,
    Uint8List? passphraseUtf8,
  });
}

/// Thrown by [TransactionSigner.sign] when the address freshly derived from
/// entropy + the supplied [passphraseUtf8] does not match the address
/// `PublicAccountCache` recorded at seed-commit time (design.md D5) — most
/// often because the user forgot to enable the passphrase toggle, or typed a
/// different passphrase than the one used to commit the vault. Nothing is
/// signed and no private key is derived when this is thrown; the failure is
/// retryable and does NOT charge the unlock throttle.
class PassphraseMismatchFailure implements Exception {
  const PassphraseMismatchFailure();

  @override
  String toString() =>
      'PassphraseMismatchFailure: derived address does not match the '
      'vault\'s cached commit-time address';
}

/// Thrown by [TransactionSigner.sign] when [SignRequest.dataType] is one
/// this vault cannot yet correctly decode, display, and digest
/// (`typedData`/`personalMessage` — GitHub #28,
/// `redoubt-critical-fix-round3` design.md D1/D4: "the guard MUST NOT rely
/// on the UI alone"). Nothing is signed and no key material is ever
/// derived when this is thrown — the rejection happens immediately after
/// the cheap header-only vault-blob pre-check, before the unlock throttle
/// is charged and before hardware-auth support is even checked, so a UI
/// bypass can never reach this vault's signing key for a request type it
/// cannot safely sign. Lifted only once decode, structured display, and
/// correct digest computation ship together for the affected type (design
/// .md's "Atomic Unblock Ordering" requirement — no partial unblock).
class UnsupportedSignRequestFailure implements Exception {
  const UnsupportedSignRequestFailure(this.dataType);

  /// The rejected [SignRequest.dataType].
  final EthSignDataType dataType;

  @override
  String toString() =>
      'UnsupportedSignRequestFailure: this wallet cannot yet verify '
      '$dataType requests, so it refuses to sign one';
}
