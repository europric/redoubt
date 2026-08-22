/// Decorator over [SecureSeedRepository] that gates read/write behind
/// [AuthService.authenticate] unconditionally, and `deleteVault` behind it
/// only when [AuthService.isSupported] is true — mirroring
/// `EthTransactionSigner.sign`'s pattern, since PIN-based vault unseal
/// (`VaultResetController.confirmReset`) already ran before deletion
/// reaches this decorator, so device auth is an additional gate when
/// available, never a substitute for the PIN (design.md: account-deletion
/// delta). `hasSeed` is deliberately NOT gated — it is a non-decrypting
/// key-presence check (design.md: used by `main.dart`'s bootstrap before
/// `runApp`, explicitly "not biometric-gated").
///
/// This is the structural guarantee design.md's "Secure Storage Design"
/// section calls out: every consumer of the vault's seed depends on the
/// [SecureSeedRepository] interface, and the composition root wires this
/// decorator as the only implementation consumers ever see — so no call
/// site can accidentally skip authentication by reaching for the
/// undecorated repository instead.
library;

import 'dart:typed_data';

import 'auth_service.dart';
import 'secure_seed_repository.dart';

class AuthenticatedSeedRepository implements SecureSeedRepository {
  final SecureSeedRepository repository;
  final AuthService authService;

  const AuthenticatedSeedRepository({
    required this.repository,
    required this.authService,
  });

  @override
  Future<Uint8List?> readEntropy() async {
    if (!await authService.authenticate()) {
      return null;
    }
    return repository.readEntropy();
  }

  @override
  Future<void> writeEntropy(Uint8List entropy) async {
    if (!await authService.authenticate()) {
      return;
    }
    await repository.writeEntropy(entropy);
  }

  @override
  Future<void> deleteVault() async {
    // PIN-based vault unseal (VaultResetController.confirmReset) already
    // ran before this call reaches the repository decorator — PIN remains
    // mandatory in every case. Device auth is only an ADDITIONAL gate when
    // the platform supports it, mirroring EthTransactionSigner.sign's
    // isSupported() guard (design.md: account-deletion delta).
    if (await authService.isSupported()) {
      if (!await authService.authenticate()) {
        return;
      }
    }
    await repository.deleteVault();
  }

  @override
  Future<bool> hasSeed() => repository.hasSeed();
}
