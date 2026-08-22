/// The in-memory PIN carrier that lets the onboarding flow collect a PIN
/// once, at `/onboarding/pin`, and hand it off to the actual seed-commit
/// call — `VaultCommitService.commit(entropy, draft.takePin())` — without
/// threading it through `extra` across the five routes between PIN entry
/// and the real commit point (biometric-unlock-onboarding design.md D3).
///
/// Owned by [VaultScope] as a stable singleton (same lifetime as
/// `onboardingDraft`'s composition-root peers, e.g. `vaultCommitService`).
///
/// **Ownership handoff, not double-zeroization** (design.md D3): [takePin]
/// relinquishes ownership of the held [Uint8List] to its caller — it does
/// NOT zero-fill the returned bytes itself. The caller (in production,
/// `VaultCommitService.commit`) is the one that zeroizes it, in its own
/// `finally` block, after actually using it. [clear] is the opposite case —
/// an abandoned draft (e.g. backing out to `/onboarding/pin`, or
/// `VaultScope.refreshVaultState()` running after every commit/deletion) —
/// where nothing downstream will ever consume the bytes, so they ARE
/// actively zero-filled here.
library;

import 'dart:typed_data';

class OnboardingDraft {
  Uint8List? _pin;
  Uint8List? _passphrase;

  /// Whether a PIN is currently held (set via [setPin], not yet relinquished
  /// via [takePin] or discarded via [clear]).
  bool get hasPin => _pin != null;

  /// Whether a passphrase is currently held (set via [setPassphrase], not
  /// yet relinquished via [takePassphrase] or discarded via [clear]).
  bool get hasPassphrase => _passphrase != null;

  /// Stores [pin], replacing (WITHOUT zeroizing) any previously held PIN.
  /// Callers that need the previous PIN's bytes wiped first should call
  /// [clear] explicitly before calling this again.
  void setPin(Uint8List pin) {
    _pin = pin;
  }

  /// Relinquishes ownership of the held PIN to the caller and forgets this
  /// draft's own reference to it ([hasPin] becomes `false`). The returned
  /// bytes are handed over UNMODIFIED — the caller is now responsible for
  /// zeroizing them once done (design.md D3).
  ///
  /// Throws [StateError] if no PIN is currently held (no [setPin] call yet,
  /// or already relinquished by a prior [takePin]/[clear] call) — a
  /// programmer-error precondition, mirroring this codebase's other
  /// `commitWithPin`-style guards (e.g. `SeedVerifyController.commitWithPin`).
  Uint8List takePin() {
    final pin = _pin;
    if (pin == null) {
      throw StateError('takePin() called with no PIN currently held');
    }
    _pin = null;
    return pin;
  }

  /// Actively zero-fills any still-held PIN and forgets it. A safe no-op if
  /// no PIN is currently held (in particular, calling this again after
  /// [takePin] already relinquished ownership does nothing — the bytes are
  /// no longer reachable from this draft to re-zeroize).
  void clear() {
    final pin = _pin;
    if (pin != null) {
      pin.fillRange(0, pin.length, 0);
    }
    _pin = null;

    final passphrase = _passphrase;
    if (passphrase != null) {
      passphrase.fillRange(0, passphrase.length, 0);
    }
    _passphrase = null;
  }

  /// Stores [passphraseUtf8], the optional BIP-39 passphrase ("25th word",
  /// seed-passphrase-25th-word design.md D1/D3). Unlike [setPin], this
  /// ACTIVELY zero-fills any previously held passphrase in place before
  /// storing the new one — a deliberate improvement, not a bug fix applied
  /// to [setPin]: "regenerate" legitimately re-enters the passphrase, so the
  /// old buffer would otherwise leak past its usefulness.
  void setPassphrase(Uint8List passphraseUtf8) {
    final previous = _passphrase;
    if (previous != null) {
      previous.fillRange(0, previous.length, 0);
    }
    _passphrase = passphraseUtf8;
  }

  /// Relinquishes ownership of the held passphrase to the caller and forgets
  /// this draft's own reference to it ([hasPassphrase] becomes `false`).
  ///
  /// Deliberately does NOT mirror [takePin]'s [StateError]: "no passphrase"
  /// is the default state, not a programmer error, so this returns an empty
  /// (`Uint8List(0)`) buffer when nothing was ever set — it never throws.
  Uint8List takePassphrase() {
    final passphrase = _passphrase;
    _passphrase = null;
    return passphrase ?? Uint8List(0);
  }

  /// Actively zero-fills a still-held passphrase and forgets it, WITHOUT
  /// touching any held PIN — unlike [clear], which wipes both. Used to
  /// undo a speculative [setPassphrase] write (e.g. `SeedImportPage` sets
  /// the passphrase before calling `import()` to avoid a Completer/
  /// microtask race with the router's `onImported` callback, then must
  /// roll that write back if the import turns out to be invalid, without
  /// discarding a PIN the user may have already set during onboarding).
  /// A safe no-op if no passphrase is currently held.
  void clearPassphrase() {
    final passphrase = _passphrase;
    if (passphrase != null) {
      passphrase.fillRange(0, passphrase.length, 0);
    }
    _passphrase = null;
  }
}
