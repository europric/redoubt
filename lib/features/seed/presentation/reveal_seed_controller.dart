import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

import '../domain/mnemonic.dart';
import '../domain/mnemonic_service.dart';

/// Owns the reveal-seed PIN step (route `/account/reveal-seed/pin`,
/// vault-secure-storage-redesign gap-closure): closes the `ethereum-account`
/// spec's "Mnemonic still requires a separate gated flow" scenario — the
/// Account screen never shows the mnemonic directly (`ethereum-account`
/// spec's "Address Display Without Re-Exposing Seed" requirement); reaching
/// it requires this PIN-gated controller.
///
/// **Wrong PIN vs corrupt blob are different failures** (mirrors
/// `SignReviewController.confirmAndSign`'s exact shape, design.md's
/// decision): [WrongPinFailure] is caught here and turned into a retryable
/// [error] — the caller stays on the PIN entry step.
/// `MalformedVaultBlobFailure`/`UnsupportedVaultVersionFailure` are
/// deliberately NOT caught — they propagate to [reveal]'s caller, which
/// should route to the existing vault recovery flow instead of offering a
/// PIN retry.
///
/// **D8 guard (bip39-nfkd-normalization PR2)**: `UnsupportedMnemonicLanguageFailure`
/// IS caught here — after open, before `fromEntropy` — and turned into a
/// terminal [AsyncError] naming the problem, so no words are ever rendered
/// from a substituted-default-language re-encode.
///
/// **Zeroization**: the raw entropy bytes [openVaultBlobInBackground]
/// returns are zero-filled in a `finally` block once [mnemonicService]
/// .fromEntropy has built its own, distinct copy for the exposed [mnemonic]
/// — same raw-vs-returned-copy split `VaultCipher.open()`'s own doc comment
/// explains. The exposed [mnemonic]'s own entropy buffer is the caller's
/// responsibility to zeroize once the reveal-seed view is left (see
/// `Mnemonic.zeroize`'s doc comment).
class RevealSeedController extends ChangeNotifier {
  RevealSeedController({
    required this.sealedVaultRepository,
    required this.mnemonicService,
  });

  final SealedVaultRepository sealedVaultRepository;
  final MnemonicService mnemonicService;

  AsyncState<Mnemonic> _state = const AsyncIdle<Mnemonic>();
  AsyncState<Mnemonic> get state => _state;

  /// Attempts to open the stored vault blob with [pin] and, on success,
  /// builds a [Mnemonic] from the decrypted entropy, exposed via [state] as
  /// [AsyncData]. If no blob is stored at all (no vault — should be
  /// unreachable from `/account`, which only renders once
  /// `VaultState.current`), sets [state] to [AsyncError] instead of
  /// crashing. If opening throws [WrongPinFailure], sets a retryable
  /// [AsyncError] and leaves no data exposed.
  /// `MalformedVaultBlobFailure`/`UnsupportedVaultVersionFailure` propagate
  /// unchanged to the caller (see this class's own doc comment).
  Future<void> reveal(Uint8List pin) async {
    _state = const AsyncLoading<Mnemonic>();
    notifyListeners();

    VaultSecret? secret;
    try {
      final blob = await sealedVaultRepository.readBlob();
      if (blob == null) {
        _state = const AsyncError<Mnemonic>('No vault is present.');
        return;
      }

      secret = await openVaultBlobInBackground(blob: blob, pin: pin);
      // D8 guard — after open, before fromEntropy: an unsupported
      // persisted language renders no words rather than falling back to
      // an English re-encode of a non-English vault's entropy.
      final language = secret.requireLanguage();
      _state = AsyncData<Mnemonic>(
        mnemonicService.fromEntropy(secret.entropy, language: language),
      );
    } on WrongPinFailure {
      _state = const AsyncError<Mnemonic>('Incorrect PIN. Please try again.');
    } on UnsupportedMnemonicLanguageFailure {
      _state = const AsyncError<Mnemonic>(
        'This vault was created with a recovery phrase language this app '
        'version cannot open. Update the app.',
      );
    } finally {
      secret?.zeroize();
      // Demote a still-loading state to idle without clobbering a terminal
      // AsyncData/AsyncError — matters when an exception propagates past
      // this finally block (see design.md's "the finally demotes a
      // still-loading state" decision).
      if (_state is AsyncLoading<Mnemonic>) {
        _state = const AsyncIdle<Mnemonic>();
      }
      notifyListeners();
    }
  }

  /// Zeroizes the revealed mnemonic's entropy buffer before this
  /// controller is discarded (#30, `seed-exposure-protection` spec) — the
  /// whole point of gating this screen behind a PIN is defeated if the
  /// revealed phrase's entropy survives past the screen's own lifetime.
  @override
  void dispose() {
    _state.dataOrNull?.zeroize();
    super.dispose();
  }
}
