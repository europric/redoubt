/// Feature-owned port replacing the direct
/// `features/seed/presentation -> lib/config` `VaultCommitService` coupling
/// (hexagonal-architecture-refactor design.md D6). `SeedVerifyController`
/// and `SeedImportController` depend on this interface instead of the
/// concrete composition-root orchestrator, so `features/seed/presentation`
/// never imports `lib/config/**` directly.
///
/// `VaultCommitService implements SeedCommitter`: its own `commit` returns
/// `Future<DerivedAccount>`, a valid override of this interface's
/// `Future<void>` (both current call sites already discard the return
/// value), so no signature/body change was needed on `VaultCommitService`
/// itself to satisfy this port.
library;

import 'dart:typed_data';

import 'package:redoubt/core/bip39/bip39.dart';

abstract interface class SeedCommitter {
  /// Seals [entropy] under [pin] (optionally with a BIP-39 [passphraseUtf8],
  /// the "25th word") and durably commits it as the vault's sealed blob.
  /// Implementations MUST zeroize [entropy], [pin], and [passphraseUtf8]
  /// (when provided) once this call returns or throws.
  ///
  /// [language] is the mnemonic's source wordlist — REQUIRED, never
  /// defaulted (bip39-nfkd-normalization design.md), so it can be threaded
  /// through to derivation and (Phase 2) written into the sealed plaintext
  /// alongside [entropy].
  Future<void> commit(
    Uint8List entropy,
    Uint8List pin, {
    required MnemonicLanguage language,
    Uint8List? passphraseUtf8,
  });
}
