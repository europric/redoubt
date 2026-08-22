import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/core/security/security.dart';

import '../domain/sign_request.dart';
import '../domain/signed_result.dart';
import '../domain/transaction_signer.dart';

/// Owns the Sign Review screen's confirm-and-sign step (route
/// `/account/sign`).
///
/// `qr-air-gapped-signing` spec's "Offline Sign And BC-UR Signature Output"
/// requirement: signing only happens through [signer], which requires a
/// correct PIN (`vault-unlock` spec, mandatory) plus a successful
/// biometric/passcode hardware wrap when available (vault-secure-storage-
/// redesign PR7's `EthTransactionSigner` — same composition pattern
/// `AccountController` used pre-PR7). A denied/cancelled/failed hardware
/// prompt makes [signer.sign] return `null`, surfaced as [error].
///
/// **Wrong PIN vs corrupt blob are different failures** (design.md
/// decision): [WrongPinFailure] is caught here and turned into a retryable
/// [error] — the caller stays on the PIN entry step. `MalformedVaultBlobFailure`/
/// `UnsupportedVaultVersionFailure` are deliberately NOT caught — they
/// propagate to [confirmAndSign]'s caller, which should route to the
/// existing vault recovery flow instead of offering a PIN retry (a
/// structurally broken blob can never be opened by any PIN).
class SignReviewController extends ChangeNotifier {
  SignReviewController({required this.request, required this.signer});

  final SignRequest request;
  final TransactionSigner signer;

  AsyncState<SignedResult> _state = const AsyncIdle<SignedResult>();
  AsyncState<SignedResult> get state => _state;

  /// The optional BIP-39 passphrase ("25th word") collected via the
  /// disclosure-neutral `PassphraseOptInField` hosted on `SignReviewPage`
  /// (design.md D4). Held HERE — not on the page's widget state — because
  /// this controller instance is the SAME instance already forwarded to the
  /// `/account/sign/pin` step via `extra:` (documented existing invariant),
  /// so [confirmAndSign] can read it back without any new plumbing. `null`
  /// (never set, or the toggle left unchecked/invalid) means "no
  /// passphrase" — byte-identical to this controller's pre-passphrase
  /// signing behavior.
  Uint8List? _passphraseUtf8;

  /// Sets (or clears, via `null`) the passphrase to use for the next
  /// [confirmAndSign] call. Called from `SignReviewPage`'s hosted
  /// `PassphraseOptInField.onChanged`.
  void setPassphrase(Uint8List? passphraseUtf8) {
    _passphraseUtf8 = passphraseUtf8;
  }

  /// Attempts to sign [request] using [pin] and this controller's held
  /// passphrase (see [setPassphrase]). On success exposes the
  /// [SignedResult] via [state] as [AsyncData]. If [signer] returns `null`
  /// (hardware auth denied/cancelled/failed), sets [state] to [AsyncError]
  /// instead and leaves no data exposed. If [signer] throws
  /// [WrongPinFailure], sets a retryable [AsyncError] — signing is never
  /// retried automatically. If [signer] throws [PassphraseMismatchFailure]
  /// (design.md D5 — the freshly derived address does not match this
  /// vault's commit-time address), sets a DISTINCT retryable [AsyncError]
  /// telling the user the passphrase doesn't match this vault and the sign
  /// was blocked — never the generic denied-auth message, and never
  /// confused with an incorrect PIN. `MalformedVaultBlobFailure`/
  /// `UnsupportedVaultVersionFailure` propagate unchanged to the caller
  /// (see this class's own doc comment). The held passphrase is zeroized
  /// in [finally] regardless of outcome and never reused across calls.
  Future<void> confirmAndSign(Uint8List pin) async {
    _state = const AsyncLoading<SignedResult>();
    notifyListeners();

    final passphraseUtf8 = _passphraseUtf8;
    try {
      final result = await signer.sign(
        request,
        pin: pin,
        passphraseUtf8: passphraseUtf8,
      );
      if (result == null) {
        _state = const AsyncError<SignedResult>(
          'Authentication was denied or cancelled. Nothing was signed.',
        );
        return;
      }
      _state = AsyncData<SignedResult>(result);
    } on WrongPinFailure {
      _state = const AsyncError<SignedResult>(
        'Incorrect PIN. Please try again.',
      );
    } on PassphraseMismatchFailure {
      _state = const AsyncError<SignedResult>(
        "This passphrase doesn't match this vault. The sign was blocked "
        '— nothing was signed. Check the passphrase and try again.',
      );
    } finally {
      if (passphraseUtf8 != null) {
        passphraseUtf8.fillRange(0, passphraseUtf8.length, 0);
      }
      _passphraseUtf8 = null;
      // Demote a still-loading state to idle without clobbering a terminal
      // AsyncData/AsyncError — matters when an exception propagates past
      // this finally block (see design.md's "the finally demotes a
      // still-loading state" decision).
      if (_state is AsyncLoading<SignedResult>) {
        _state = const AsyncIdle<SignedResult>();
      }
      notifyListeners();
    }
  }
}
