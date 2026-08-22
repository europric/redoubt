/// A single sealed type modeling an async operation's lifecycle
/// (idle/loading/data/error), replacing the per-controller hand-rolled
/// `_loading`/`_error` fields this codebase used before
/// `state-management-foundation` (design.md's "`AsyncState<T>`: 4
/// variants, no extra payload" decision).
///
/// **No `==`/`hashCode`/`toString()` override — deliberate, load-bearing**:
/// a future `AsyncState<Mnemonic>` (Change 2) must never transitively
/// compare or print secret `entropy` through this wrapper. Every variant
/// uses `Object`'s default identity equality; two [AsyncData] instances
/// wrapping equal-by-value payloads are NOT `==` to each other unless they
/// are the same instance. See `test/core/presentation/async_state_test.dart`'s
/// "No value-equality guard" group.
///
/// Feature-specific progress (e.g. `ScanController.progress`) stays a
/// separately typed controller field, not an `Object? progress` payload on
/// [AsyncLoading] — see design.md's "Rejected: `Object? progress` on
/// AsyncLoading" note.
library;

sealed class AsyncState<T> {
  const AsyncState();
}

/// No async operation has started yet.
final class AsyncIdle<T> extends AsyncState<T> {
  const AsyncIdle();
}

/// An async operation is in flight.
final class AsyncLoading<T> extends AsyncState<T> {
  const AsyncLoading();
}

/// An async operation completed successfully with [value].
final class AsyncData<T> extends AsyncState<T> {
  const AsyncData(this.value);

  final T value;
}

/// An async operation failed. [message] is already a human-readable
/// `String` — exceptions are mapped to text at the controller boundary, not
/// carried as `Object` (design.md: "`AsyncError.message` is `String`, not
/// `Object`").
final class AsyncError<T> extends AsyncState<T> {
  const AsyncError(this.message);

  final String message;
}

/// Convenience accessors over [AsyncState], avoiding a `switch` at every
/// call site for the common cases.
extension AsyncStateX<T> on AsyncState<T> {
  /// The wrapped value if this state is [AsyncData], otherwise `null`.
  T? get dataOrNull => switch (this) {
    AsyncData<T>(:final value) => value,
    _ => null,
  };

  /// The error message if this state is [AsyncError], otherwise `null`.
  String? get errorOrNull => switch (this) {
    AsyncError<T>(:final message) => message,
    _ => null,
  };

  /// Whether this state is [AsyncLoading].
  bool get isLoading => switch (this) {
    AsyncLoading<T>() => true,
    _ => false,
  };
}
