import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';

import '../domain/mnemonic.dart';
import '../domain/mnemonic_service.dart';
import '../domain/seed_committer.dart';

/// Owns the "import an existing phrase" flow (route `/import`).
///
/// `seed-lifecycle` spec's "Import Existing Mnemonic With Validation"
/// requirement: any standard-length (12/15/18/21/24-word) phrase — not
/// only one this app generated — is accepted after wordlist + checksum
/// validation; anything else is rejected with nothing persisted.
///
/// **PIN-setup cutover (vault-secure-storage-redesign PR7, task 8.5)**:
/// [import] now ONLY validates the phrase and exposes the parsed
/// mnemonic via [importState] — it no longer persists anything.
/// Persistence moves to [commitWithPin], reached via the new PIN-setup step
/// inserted between import validation and the actual vault commit (mirrors
/// `SeedVerifyController`'s own cutover).
///
/// **`state-management-foundation` AsyncState migration
/// (seed-import-controller-migration, 2c-1, design.md D1)**: TWO
/// `AsyncState` fields, not one — [importState] (`AsyncState<Mnemonic>`)
/// and [commitState] (`AsyncState<void>`) — replacing the previous six
/// hand-rolled `_importing`/`_error`/`_imported`/`_mnemonic`/`_committing`/
/// `_committed` fields. They never write each other: the validated
/// [Mnemonic] lives only in `importState`'s `AsyncData.value`, and a
/// `commitWithPin` failure surfaces solely via `commitState`, never
/// bleeding into `importState`'s error slot (this matters because
/// `/import/pin-setup` is `push`ed, so `SeedImportPage` stays mounted and
/// subscribed underneath).
class SeedImportController extends ChangeNotifier {
  SeedImportController({
    required this.mnemonicService,
    required this.vaultCommitService,
  });

  final MnemonicService mnemonicService;
  final SeedCommitter vaultCommitService;

  AsyncState<Mnemonic> _importState = const AsyncIdle<Mnemonic>();
  AsyncState<Mnemonic> get importState => _importState;

  AsyncState<void> _commitState = const AsyncIdle<void>();
  AsyncState<void> get commitState => _commitState;

  final Completer<void> _imported = Completer<void>();

  /// Resolves exactly once, the first time [import] succeeds — mirrors
  /// `ScanController.completed`'s one-shot pattern (design.md D2). `void`,
  /// not [Mnemonic]: the caller (`SeedImportPage`) only needs a completion
  /// signal to trigger navigation, and resolving a `Future` with entropy
  /// would retain the secret past this controller's life. A later
  /// `import()`/`commitWithPin()` call never completes this a second time.
  Future<void> get imported => _imported.future;

  /// Validates [phrase]. On success, parses and exposes it via
  /// [importState] as [AsyncData] and resolves [imported] — nothing is
  /// persisted yet; the caller MUST proceed to a PIN-setup step and call
  /// [commitWithPin]. On an invalid phrase, sets [importState] to
  /// [AsyncError] and leaves [imported] unresolved.
  ///
  /// [mnemonicService.isValid]/[mnemonicService.fromPhrase] are synchronous,
  /// so this method never actually spends any time in [AsyncLoading] — it
  /// still assigns and notifies that transitional state (for API/UI
  /// consistency with every other `AsyncState`-driven controller) before
  /// immediately landing on the terminal state in the same synchronous
  /// pass. No artificial `await` boundary is introduced solely to make
  /// [AsyncLoading] observable; this method's real-world timing is
  /// unchanged from before this migration.
  Future<void> import(String phrase) async {
    _importState = const AsyncLoading<Mnemonic>();
    notifyListeners();

    final normalized = phrase.trim();
    if (!mnemonicService.isValid(normalized)) {
      _importState = const AsyncError<Mnemonic>(
        'This is not a valid recovery phrase. Check the words and try again.',
      );
      notifyListeners();
      return;
    }

    _importState = AsyncData<Mnemonic>(mnemonicService.fromPhrase(normalized));
    if (!_imported.isCompleted) _imported.complete();
    notifyListeners();
  }

  /// Seals the validated mnemonic's entropy under [pin] and commits the
  /// vault via [vaultCommitService]. On success lands [commitState] in
  /// [AsyncData]. On failure lands [commitState] in [AsyncError] and
  /// leaves [importState] untouched (D1.3's cross-operation error
  /// isolation). Throws [StateError] if called before a successful
  /// [import] — a programmer-error precondition, unchanged, not surfaced
  /// via [AsyncState].
  Future<void> commitWithPin(Uint8List pin, {Uint8List? passphraseUtf8}) async {
    final mnemonic = _importState.dataOrNull;
    if (mnemonic == null) {
      throw StateError('commitWithPin() called before a successful import()');
    }

    _commitState = const AsyncLoading<void>();
    notifyListeners();

    try {
      await vaultCommitService.commit(
        mnemonic.entropy,
        pin,
        language: mnemonic.language,
        passphraseUtf8: passphraseUtf8,
      );
      _commitState = const AsyncData<void>(null);
    } catch (_) {
      _commitState = const AsyncError<void>(
        'Could not set up your vault. Please try again.',
      );
    } finally {
      notifyListeners();
    }
  }

  /// Commits using [draft]'s already-collected PIN
  /// (biometric-unlock-onboarding design.md D3) — mirrors
  /// `SeedVerifyController.commitWithDraft`'s own onboarding-integrated
  /// commit path. Delegates to [commitWithPin], so this also throws
  /// [StateError] if called before a successful [import].
  ///
  /// Throws [StateError] if [draft.hasPin] is `false` — callers MUST check
  /// [OnboardingDraft.hasPin] first and fall back to the existing
  /// `import.pinSetup` route when it is (design.md D3's abort/fallback).
  Future<void> commitWithDraft(OnboardingDraft draft) {
    if (!draft.hasPin) {
      throw StateError(
        'commitWithDraft() called with no PIN held by the OnboardingDraft',
      );
    }
    return commitWithPin(
      draft.takePin(),
      passphraseUtf8: draft.takePassphrase(),
    );
  }
}
