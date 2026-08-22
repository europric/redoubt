import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:redoubt/core/presentation/presentation.dart';
import 'package:redoubt/features/onboarding/onboarding.dart';

import '../domain/mnemonic.dart';
import '../domain/seed_committer.dart';

/// Owns the re-entry verification step of the seed lifecycle
/// (route `/generate/verify`).
///
/// **PIN-setup cutover (vault-secure-storage-redesign PR7, task 8.5)**:
/// [verify] now ONLY checks the re-entry challenge — it no longer persists
/// anything. Persistence moves to [commitWithPin], reached via the new
/// PIN-setup step inserted between word verification and the actual vault
/// commit (`vault-unlock` spec's "PIN Setup With Minimum Numeric Policy"
/// requirement: every user MUST set a PIN before the vault is usable, no
/// exceptions). [commitWithPin] delegates to [vaultCommitService], which
/// seals [mnemonic]'s entropy as a v1 blob (never legacy plaintext hex).
///
/// **`state-management-foundation` AsyncState migration
/// (seed-verify-controller-migration, 2c-2, design.md D1)**: TWO
/// `AsyncState<void>` fields — [verifyState] and [commitState] — replacing
/// the previous five hand-rolled `_verifying`/`_error`/`_verified`/
/// `_committing`/`_committed` fields. They never write each other: a
/// `commitWithPin` failure surfaces solely via `commitState`, never bleeding
/// into `verifyState`'s error slot (this matters because
/// `/generate/verify/pin-setup` is `push`ed, so `SeedVerifyPage` stays
/// mounted and subscribed underneath).
class SeedVerifyController extends ChangeNotifier {
  SeedVerifyController({
    required this.mnemonic,
    required this.vaultCommitService,
    List<int>? challengeIndexes,
    Random? random,
  }) : challengeIndexes =
           challengeIndexes ??
           _randomChallengeIndexes(
             mnemonic.words.length,
             random ?? Random.secure(),
           );

  final Mnemonic mnemonic;
  final SeedCommitter vaultCommitService;

  /// The word positions (0-indexed) the user must correctly re-enter.
  final List<int> challengeIndexes;

  AsyncState<void> _verifyState = const AsyncIdle<void>();
  AsyncState<void> get verifyState => _verifyState;

  AsyncState<void> _commitState = const AsyncIdle<void>();
  AsyncState<void> get commitState => _commitState;

  final Completer<void> _verified = Completer<void>();

  /// Resolves exactly once, the first time [verify] succeeds — mirrors
  /// `SeedImportController.imported`'s one-shot pattern (design.md D2).
  /// `void`, not a payload: the caller (`SeedVerifyPage`) only needs a
  /// completion signal to trigger navigation. A later `verify()`/
  /// `commitWithPin()` call never completes this a second time.
  Future<void> get verified => _verified.future;

  /// One uniformly-random index per 6-word quadrant (words 0-5, 6-11,
  /// 12-17, 18-23), drawn from [random] (design.md D4). **No longer** a
  /// pure function of word count — this retires the previous
  /// `_defaultChallengeIndexes` invariant, since two controllers built with
  /// the same [mnemonic] length may now select different indexes. Callers
  /// that need reproducibility MUST inject a seeded [Random] (or the
  /// explicit `challengeIndexes` override) — never re-derive indexes from
  /// entropy/key material.
  static const _quadrantSize = 6;

  static List<int> _randomChallengeIndexes(int wordCount, Random random) {
    final indexes = <int>[];
    for (var start = 0; start < wordCount; start += _quadrantSize) {
      final size = min(_quadrantSize, wordCount - start);
      indexes.add(start + random.nextInt(size));
    }
    return indexes;
  }

  /// Checks [answers] (challenge index -> entered word) against the
  /// original mnemonic. On success, lands [verifyState] in [AsyncData] and
  /// resolves [verified] — nothing is persisted yet; the caller MUST
  /// proceed to a PIN-setup step and call [commitWithPin]. On failure, lands
  /// [verifyState] in [AsyncError] and leaves [verified] unresolved; the
  /// caller may call [verify] again to retry.
  ///
  /// This method is a pure string comparison over [challengeIndexes] plus
  /// `notifyListeners()` — it never actually spends any time in
  /// [AsyncLoading]. It still assigns and notifies that transitional state
  /// (for API/UI consistency with every other `AsyncState`-driven
  /// controller) before immediately landing on the terminal state in the
  /// same synchronous pass. No artificial `await` boundary is introduced
  /// solely to make [AsyncLoading] observable; this method's real-world
  /// timing is unchanged from before this migration.
  Future<void> verify(Map<int, String> answers) async {
    _verifyState = const AsyncLoading<void>();
    notifyListeners();

    final allCorrect = challengeIndexes.every(
      (i) =>
          answers[i]?.trim().toLowerCase() == mnemonic.words[i].toLowerCase(),
    );

    if (!allCorrect) {
      _verifyState = const AsyncError<void>(
        'One or more words are incorrect. Please try again.',
      );
      notifyListeners();
      return;
    }

    _verifyState = const AsyncData<void>(null);
    if (!_verified.isCompleted) _verified.complete();
    notifyListeners();
  }

  /// Seals [mnemonic]'s entropy under [pin] and commits the vault via
  /// [vaultCommitService]. On success lands [commitState] in [AsyncData].
  /// On failure lands [commitState] in [AsyncError] and leaves [verifyState]
  /// untouched (D1's cross-operation error isolation) — the caller may retry
  /// with a (possibly different) PIN. Throws [StateError] if called before a
  /// successful [verify] — a new programmer-error precondition, gated on the
  /// [_verified] `Completer` (NOT on `verifyState.dataOrNull == null`, which
  /// is indistinguishable from idle for `AsyncState<void>`), never surfaced
  /// via [AsyncState] or any user-facing error text.
  Future<void> commitWithPin(Uint8List pin, {Uint8List? passphraseUtf8}) async {
    if (!_verified.isCompleted) {
      throw StateError('commitWithPin() called before a successful verify()');
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
  /// (biometric-unlock-onboarding design.md D3) — the onboarding-integrated
  /// commit path, reached when the user already set a PIN during
  /// `/onboarding/pin`, instead of prompting again on a fresh
  /// `PinSetupPage`. Delegates to [commitWithPin] (identical AsyncState/
  /// zeroization/precondition behavior — only the PIN's source differs), so
  /// this also throws [StateError] if called before a successful [verify].
  ///
  /// Throws [StateError] if [draft.hasPin] is `false` — callers MUST check
  /// [OnboardingDraft.hasPin] first and fall back to the existing
  /// `generate.pinSetup` route when it is (design.md D3's abort/fallback:
  /// hot-restart draft loss, or the recovery-page re-import path).
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
