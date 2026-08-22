/// Failed-unlock-attempt throttle: exponential backoff, persisted across
/// restarts, backoff-only -- NEVER auto-wipes (`vault-unlock` spec's
/// "Exponential Backoff On Failed Attempts, Never Auto-Wipe" requirement;
/// design.md's "UnlockThrottle design" decision).
///
/// **Standalone in this PR**: no caller wires this class into
/// `VaultCipher`/`VaultCommitService`/any unlock UI yet (that lands in
/// PR7, gated on the Phase 9 device benchmark). This file only has to be
/// correct in isolation -- its own state machine and persistence. A future
/// caller would use it as:
/// ```dart
/// final remaining = await throttle.remainingDelay();
/// if (remaining > Duration.zero) { /* block submit, show countdown */ }
/// await throttle.recordAttemptStart(); // BEFORE the KDF runs
/// try {
///   final plaintext = await VaultCipher.open(blob: blob, pin: pin);
///   await throttle.recordSuccess();
///   // ... use plaintext ...
/// } on WrongPinFailure {
///   // Already charged by recordAttemptStart() above -- nothing else to do.
/// } on MalformedVaultBlobFailure {
///   // NOT a PIN failure -- do not charge. A caller wanting "never charge
///   // for a structurally broken blob" (design.md's failure-classification
///   // decision) would call recordAttemptStart() only AFTER confirming the
///   // header parses with a known version, or would explicitly not treat
///   // this branch as chargeable. Left to the PR7 caller.
/// }
/// ```
///
/// **Closed-form backoff schedule** (design.md):
/// `delay(n) = 0 for n<=2; min(1s * 5^(n-3), 15min) for n>=3` -->
/// `0,0,0,1s,5s,25s,2m05s,10m25s,15m,15m,...`. Matches the proposal's
/// "1s,5s,30s,5min,..." intent as a closed form with a 15-minute ceiling.
///
/// **Persisted BEFORE the attempt** (`recordAttemptStart`): increments the
/// counter and stamps the attempt time durably BEFORE any KDF work runs --
/// killing the app mid-derivation cannot dodge the count. A verified-correct
/// unlock must separately call [recordSuccess] to clear the optimistic
/// charge; [recordAttemptStart] never assumes success.
///
/// **No double-charging**: [remainingDelay] computes
/// `max(0, delay(n) - (now - lastAttemptAtMs))`, crediting the failed
/// attempt's own Argon2id runtime (plus any retype time) toward the wait --
/// a legitimate user is not penalized twice for the KDF's own cost.
///
/// **Resets ONLY on success, never decays with elapsed time**: the counter
/// is unaffected by the passage of time alone -- only [recordSuccess]
/// clears it. [remainingDelay] still shrinks as time passes (the no-double-
/// charging credit above), but [failedAttempts] itself never decreases on
/// its own.
///
/// **Never auto-wipes**: this class has no dependency on `deleteVault()` or
/// any vault-storage type at all -- there is no code path from here to
/// vault deletion, by construction, no matter how many failures accumulate.
///
/// **Clock-rollback clamp**: a backward wall-clock jump clamps the elapsed
/// time credited toward the wait to zero (never negative), so
/// [remainingDelay] never exceeds the full un-credited [delayForFailedAttempts]
/// value and never goes negative. Forward clock jumps are unpreventable
/// without trusted time -- this is a speed bump, not a hard guarantee
/// (design.md's "Clock caveat").
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The fakeable boundary over vault unlock throttling.
abstract interface class UnlockThrottle {
  /// The wait still owed before the next unlock attempt may run, crediting
  /// time already spent since the last recorded attempt. Zero if no attempt
  /// is currently pending a wait.
  Future<Duration> remainingDelay();

  /// Persists an attempt start BEFORE the KDF/AEAD check runs: increments
  /// the failed-attempt counter by one (optimistic -- assumes failure until
  /// [recordSuccess] proves otherwise) and stamps the attempt time. This
  /// write is durable and complete before this method returns -- a process
  /// death immediately afterward still leaves the incremented count
  /// persisted.
  Future<void> recordAttemptStart();

  /// Clears the failed-attempt counter back to zero. Call only after a
  /// verified-correct unlock. The ONLY way the counter ever decreases.
  Future<void> recordSuccess();

  /// The number of consecutive failed attempts recorded since the last
  /// [recordSuccess] (or ever, if [recordSuccess] has never been called).
  Future<int> failedAttempts();

  /// Removes the persisted throttle key (`vault.unlock.throttle`) entirely.
  /// Idempotent — a no-op if no attempt was ever recorded. Part of
  /// `account-deletion`'s ordered wipe (design.md D1), step 4; the sole
  /// intended production caller is `VaultResetController.confirmReset()`.
  ///
  /// **NOT a backoff-escape path** — this is NOT an alternative to
  /// [recordSuccess], which remains the only success-driven counter reset.
  Future<void> clearThrottleState();
}

class FlutterUnlockThrottle implements UnlockThrottle {
  static const _key = 'vault.unlock.throttle';
  static const _capSeconds = 15 * 60;

  // Same underlying keystore/keychain configuration as
  // `FlutterPublicAccountCache` -- reads/writes its own key
  // (`vault.unlock.throttle`), never gated by `AuthenticatedSeedRepository`
  // (the throttle state itself must be readable/writable without an
  // already-successful unlock).
  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;

  const FlutterUnlockThrottle({
    FlutterSecureStorage? storage,
    DateTime Function()? now,
  }) : _storage = storage ?? _defaultStorage,
       _now = now ?? DateTime.now;

  /// Pure closed-form backoff schedule (design.md's "UnlockThrottle design"
  /// decision): `delay(n) = 0 for n<=2; min(1s * 5^(n-3), 15min) for n>=3`.
  static Duration delayForFailedAttempts(int failedAttempts) {
    if (failedAttempts <= 2) return Duration.zero;
    final seconds = math.pow(5, failedAttempts - 3).toInt();
    return Duration(seconds: math.min(seconds, _capSeconds));
  }

  @override
  Future<int> failedAttempts() async => (await _readState()).failedAttempts;

  @override
  Future<void> recordAttemptStart() async {
    final state = await _readState();
    await _writeState(
      _ThrottleState(
        failedAttempts: state.failedAttempts + 1,
        lastAttemptAtMs: _now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> recordSuccess() async {
    await _writeState(
      const _ThrottleState(failedAttempts: 0, lastAttemptAtMs: 0),
    );
  }

  @override
  Future<Duration> remainingDelay() async {
    final state = await _readState();
    if (state.failedAttempts == 0) return Duration.zero;

    final delay = delayForFailedAttempts(state.failedAttempts);
    final lastAttemptAt = DateTime.fromMillisecondsSinceEpoch(
      state.lastAttemptAtMs,
    );

    var elapsed = _now().difference(lastAttemptAt);
    if (elapsed.isNegative) {
      // Clock-rollback clamp: a backward wall-clock jump must not credit
      // negative time (which would inflate the remaining wait) and must
      // not be treated as "no time has passed since forever" either -- it
      // simply credits nothing for this read.
      elapsed = Duration.zero;
    }

    final remaining = delay - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  Future<void> clearThrottleState() => _storage.delete(key: _key);

  Future<_ThrottleState> _readState() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) {
      return const _ThrottleState(failedAttempts: 0, lastAttemptAtMs: 0);
    }
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return _ThrottleState(
      failedAttempts: map['failedAttempts'] as int,
      lastAttemptAtMs: map['lastAttemptAtMs'] as int,
    );
  }

  Future<void> _writeState(_ThrottleState state) => _storage.write(
    key: _key,
    value: jsonEncode({
      'failedAttempts': state.failedAttempts,
      'lastAttemptAtMs': state.lastAttemptAtMs,
    }),
  );
}

class _ThrottleState {
  const _ThrottleState({
    required this.failedAttempts,
    required this.lastAttemptAtMs,
  });

  final int failedAttempts;
  final int lastAttemptAtMs;
}
