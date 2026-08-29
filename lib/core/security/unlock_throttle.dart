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
/// **Integrity + total read path (#19)**: the persisted record carries a
/// SHA-256 digest (`package:crypto`) computed over the canonical string
/// `"v1|N|M"` (parsed ints, never re-serialized JSON -- key order is not a
/// stable contract). The read path (`_decodeStoredState`) is total over
/// ANY stored bytes: malformed JSON, wrong-type fields, a negative count,
/// an out-of-range timestamp, or a digest mismatch all resolve to a safe
/// default (`{failedAttempts: 8, lastAttemptAtMs: now}` -- already at the
/// 15-minute cap, never a permanent lockout) instead of throwing. A
/// pre-existing well-formed record with no `digest` key is trusted as
/// legacy state and silently upgraded, not treated as tampered. This is
/// tamper-EVIDENCE, not tamper-proofing: an attacker with delete access to
/// the underlying secure-storage key already resets the counter to zero
/// for free, with or without this digest -- a documented, accepted scope
/// boundary, not an oversight.
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

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
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

  /// Inclusive bound of `DateTime.fromMillisecondsSinceEpoch`'s
  /// representable range on the pinned Dart SDK (verified against Dart
  /// 3.13.0 at apply time: `-8640000000000000..8640000000000000`, ~100M
  /// days either side of the epoch). Any stored `lastAttemptAtMs` outside
  /// `0..8640000000000000` is treated as corrupt (#19) -- rejected BEFORE
  /// `DateTime.fromMillisecondsSinceEpoch` is ever called with it.
  static const _maxEpochMs = 8640000000000000;

  /// #27 TOCTOU fix (design.md D3): class-level (not per-instance) tail
  /// that serializes read-modify-write access to the single
  /// `vault.unlock.throttle` storage key across every [FlutterUnlockThrottle]
  /// instance. Class-scoped, not instance-scoped, because this class has a
  /// `const` constructor and is built as `const FlutterUnlockThrottle()` at
  /// multiple call sites — an instance field would force dropping `const`,
  /// splitting one canonicalized object into unsynchronized instances that
  /// all still share the same underlying storage key. The tail never
  /// carries an error forward (a throwing op is caught and completed on its
  /// own [Completer], never left on `_tail` itself), so one failing
  /// operation cannot poison every later one queued behind it. Only the
  /// three writers ([recordAttemptStart], [recordSuccess],
  /// [clearThrottleState]) are serialized; readers stay unserialized — a
  /// single read observing either the pre- or post-write state is always a
  /// valid observation.
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

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
    // #19 crash-vector fix: return the cap directly for n >= 8 before
    // `math.pow` ever runs -- a tampered-then-defaulted or otherwise huge
    // `failedAttempts` (e.g. 500) previously overflowed into
    // `UnsupportedError` inside `.toInt()`. 5^5 == 3125 > 900s, so this is
    // already always >= the cap for n >= 8: purely an early return, not a
    // behavior change for any value below it.
    if (failedAttempts >= 8) return const Duration(seconds: _capSeconds);
    final seconds = math.pow(5, failedAttempts - 3).toInt();
    return Duration(seconds: math.min(seconds, _capSeconds));
  }

  @override
  Future<int> failedAttempts() async =>
      (await _readStateRepairingIfNeeded()).failedAttempts;

  @override
  Future<void> recordAttemptStart() => _serialized(() async {
    // #19 (design.md D1): uses the pure, non-serializing decode directly --
    // never `_readStateRepairingIfNeeded`, which may itself re-enter the
    // class-level critical section below and would deadlock by waiting on
    // the very action it is called from. Any `needsPersist` repair signal
    // is deliberately ignored: this call's own write below already emits a
    // correctly-digested record built on top of the decoded (possibly
    // safe-default) state, so the repair is subsumed for free with zero
    // extra writes.
    final outcome = await _decodeStoredState();
    await _writeState(
      _ThrottleState(
        failedAttempts: outcome.state.failedAttempts + 1,
        lastAttemptAtMs: _now().millisecondsSinceEpoch,
      ),
    );
  });

  @override
  Future<void> recordSuccess() => _serialized(
    () => _writeState(const _ThrottleState(failedAttempts: 0, lastAttemptAtMs: 0)),
  );

  @override
  Future<Duration> remainingDelay() async {
    // #19: never called from inside a running critical-section action, so
    // the possibly-persisting repair path is safe to use here.
    final state = await _readStateRepairingIfNeeded();
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
  Future<void> clearThrottleState() => _serialized(() => _storage.delete(key: _key));

  /// #19 (design.md D1): pure, in-chain-safe read+decode. Reads the raw
  /// bytes then hands off to the fully synchronous, total [_decode] --
  /// this function itself never enters the class-level critical section,
  /// so it is the only read helper safe to call from inside a running
  /// critical-section action (i.e. from [recordAttemptStart]) without
  /// risking re-entrant deadlock.
  Future<_ReadOutcome> _decodeStoredState() async {
    final raw = await _storage.read(key: _key);
    return _decode(raw);
  }

  /// #19 (design.md D1): the ONLY read helper that may persist a repair,
  /// by entering the critical section below. Used ONLY by
  /// [failedAttempts] and [remainingDelay] -- the two public methods that
  /// are NEVER invoked from inside a running critical-section action, so
  /// entering it here cannot deadlock. Re-decodes a SECOND time INSIDE the
  /// critical section (rather than trusting the first, pre-critical-
  /// section read) so a stale read taken before entering cannot clobber a
  /// concurrent [recordSuccess]'s write with a stale repair.
  Future<_ThrottleState> _readStateRepairingIfNeeded() async {
    final first = await _decodeStoredState();
    if (!first.needsPersist) return first.state;
    try {
      return await _serialized(() async {
        final fresh = await _decodeStoredState();
        if (!fresh.needsPersist) return fresh.state;
        await _writeState(fresh.state);
        return fresh.state;
      });
    } catch (_) {
      // A persist failure here must not break the read path itself --
      // the caller still gets a usable (if unpersisted) safe value.
      return first.state;
    }
  }

  /// #19 (design.md D3): pure, synchronous, TOTAL decision tree over raw
  /// stored bytes. Never throws, never awaits, never enters the critical
  /// section. Every branch below terminates.
  _ReadOutcome _decode(String? raw) {
    if (raw == null) {
      return const _ReadOutcome(
        state: _ThrottleState(failedAttempts: 0, lastAttemptAtMs: 0),
        needsPersist: false,
      );
    }

    Map<String, dynamic>? map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) map = decoded;
    } catch (_) {
      map = null;
    }
    if (map == null) return _repair();

    final failedAttemptsRaw = map['failedAttempts'];
    final lastAttemptAtMsRaw = map['lastAttemptAtMs'];
    if (failedAttemptsRaw is! int || lastAttemptAtMsRaw is! int) {
      return _repair();
    }
    if (failedAttemptsRaw < 0) return _repair();
    if (lastAttemptAtMsRaw < 0 || lastAttemptAtMsRaw > _maxEpochMs) {
      return _repair();
    }

    if (!map.containsKey('digest')) {
      // Legacy record predating this change: trusted as-is, silently
      // upgraded with a digest on next persist -- never penalized.
      return _ReadOutcome(
        state: _ThrottleState(
          failedAttempts: failedAttemptsRaw,
          lastAttemptAtMs: lastAttemptAtMsRaw,
        ),
        needsPersist: true,
      );
    }

    final digestRaw = map['digest'];
    if (digestRaw is! String) return _repair();
    if (digestRaw.toLowerCase() !=
        _digestFor(failedAttemptsRaw, lastAttemptAtMsRaw)) {
      return _repair();
    }

    return _ReadOutcome(
      state: _ThrottleState(
        failedAttempts: failedAttemptsRaw,
        lastAttemptAtMs: lastAttemptAtMsRaw,
      ),
      needsPersist: false,
    );
  }

  _ReadOutcome _repair() => _ReadOutcome(
    state: _ThrottleState(
      failedAttempts: 8,
      lastAttemptAtMs: _now().millisecondsSinceEpoch,
    ),
    needsPersist: true,
  );

  /// #19 (design.md D2): SHA-256 (`package:crypto`, synchronous -- same
  /// precedent as `lib/core/ur/xoshiro256.dart`) over the canonical string
  /// `"v1|N|M"`, built from parsed ints -- NEVER over re-serialized JSON,
  /// whose key order is not a stable contract.
  static String _digestFor(int failedAttempts, int lastAttemptAtMs) =>
      sha256.convert(utf8.encode('v1|$failedAttempts|$lastAttemptAtMs')).toString();

  Future<void> _writeState(_ThrottleState state) => _storage.write(
    key: _key,
    value: jsonEncode({
      'v': 1,
      'failedAttempts': state.failedAttempts,
      'lastAttemptAtMs': state.lastAttemptAtMs,
      'digest': _digestFor(state.failedAttempts, state.lastAttemptAtMs),
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

/// #19 (design.md D1): result of [FlutterUnlockThrottle._decode] -- the
/// decoded/repaired state, plus whether a repair still needs persisting.
class _ReadOutcome {
  const _ReadOutcome({required this.state, required this.needsPersist});

  final _ThrottleState state;
  final bool needsPersist;
}
