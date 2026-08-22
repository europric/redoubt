/// secp256k1 ECDSA signing with recovery id, and keccak256 hashing, for
/// Ethereum transaction/message signatures.
///
/// **Precondition check (design.md open question / tasks.md 2.1)**: does
/// `blockchain_utils` expose secp256k1 signing with a recovery id? **Yes.**
/// `blockchain_utils`'s `ETHSigner.signConst` (package
/// `blockchain_utils/signer/eth/eth_signer.dart`) internally recovers the
/// correct recovery id by comparing the two candidate public keys against
/// the signer's own public key (see `Secp256k1SigningKey._signEcdsaConst` in
/// the package source) and low-s normalizes the signature (EIP-2) inside
/// `_signInternal`. This satisfies the precondition; the `pointycastle`
/// fallback described in design.md is **not needed**.
///
/// Verified against the published EIP-155 example vector
/// (`test/support/fixtures/eip155_example_tx.dart`, sourced from
/// https://github.com/ethereum/EIPs/blob/master/EIPS/eip-155.md): signing
/// `keccak256(signingData)` with the example private key reproduces the
/// exact published `r`, `s` and (after applying [eip155V]) `v = 37`.
library;

import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart';

/// A raw secp256k1 ECDSA signature: `r`, `s` (already low-s normalized) and
/// `recoveryId` (`0` or `1` — the index of the correct candidate public key,
/// NOT an Ethereum `v` value; use [eip155V] to compute the wire `v`).
class EcdsaSignature {
  final BigInt r;
  final BigInt s;
  final int recoveryId;

  const EcdsaSignature({
    required this.r,
    required this.s,
    required this.recoveryId,
  });
}

/// Computes the keccak256 (NOT SHA3-256 — Ethereum's original, pre-standardization
/// Keccak padding) hash of [data].
Uint8List keccak256(List<int> data) =>
    Uint8List.fromList(QuickCrypto.keccack256Hash(data));

/// Signs a pre-computed 32-byte [hash] with the raw 32-byte [privateKey]
/// using constant-time secp256k1 ECDSA (`ETHSigner.signConst`), returning the
/// signature and which of the two candidate public keys is correct.
///
/// Throws [ArgumentError] if [hash] is not exactly 32 bytes.
EcdsaSignature signHash(Uint8List privateKey, Uint8List hash) {
  if (hash.length != 32) {
    throw ArgumentError.value(hash.length, 'hash.length', 'must be 32 bytes');
  }
  final signer = ETHSigner.fromKeyBytes(privateKey);
  final signature = signer.signConst(hash, hashMessage: false);
  return EcdsaSignature(
    r: signature.r,
    s: signature.s,
    recoveryId: signature.v - 27,
  );
}

/// Computes the EIP-155 `v` value: `recoveryId + chainId*2 + 35`.
int eip155V(int recoveryId, int chainId) => recoveryId + chainId * 2 + 35;

/// Recovers the 20-byte Ethereum address that would have produced
/// [signature] over [hash], using [signature]'s explicit `recoveryId` (does
/// NOT brute-force both candidates — callers that need to try both pass two
/// [EcdsaSignature]s with `recoveryId` 0 and 1 and compare against a known
/// address, as `test/core/eth/signing_test.dart` does).
Uint8List recoverAddress(Uint8List hash, EcdsaSignature signature) {
  final ecdsaSignature = ECDSASignature(signature.r, signature.s);
  final publicKey = ecdsaSignature.recoverPublicKey(
    hash,
    CryptoSignerConst.generatorSecp256k1,
    signature.recoveryId,
  );
  final rawPublicKey = publicKey.toBytes(EncodeType.raw);
  return Uint8List.fromList(keccak256(rawPublicKey).sublist(12));
}
