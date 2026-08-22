/// Weighted alias-method sampler (Vose's algorithm), faithfully ported
/// from the reference BC-UR fountain encoder (crates.io `ur` v0.5.2,
/// MIT/Apache) `src/sampler.rs`'s `Weighted` struct. Used by
/// [Xoshiro256.chooseDegree] to pick fountain fragment-mix degrees with
/// probability proportional to `1/degree`, so the decoder's degree
/// sampling matches real BC-UR senders/receivers bit-for-bit.
library;

import 'xoshiro256.dart';

/// A pre-built Vose alias table for sampling a weighted discrete
/// distribution in O(1) per draw.
class VoseSampler {
  final List<int> _aliases;
  final List<double> _probs;

  VoseSampler._(this._aliases, this._probs);

  /// Builds the alias table for the given (unnormalized) [weights]. Throws
  /// [ArgumentError] if any weight is negative or if the weights don't sum
  /// to a positive value — matching the reference's own panics.
  factory VoseSampler(List<double> weights) {
    for (final w in weights) {
      if (w < 0) {
        throw ArgumentError('negative probability encountered');
      }
    }
    final summed = weights.fold<double>(0, (a, b) => a + b);
    if (!(summed > 0)) {
      throw ArgumentError("probabilities don't sum to a positive value");
    }
    final count = weights.length;
    final w = List<double>.generate(count, (i) => weights[i] * count / summed);

    // Matches the reference's `(1..=count).map(|j| count - j).partition(...)`:
    // indexes are visited in descending order (count-1, count-2, ..., 0),
    // and each is pushed onto `small` or `large` in that visiting order.
    final small = <int>[];
    final large = <int>[];
    for (var j = 1; j <= count; j++) {
      final idx = count - j;
      if (w[idx] < 1.0) {
        small.add(idx);
      } else {
        large.add(idx);
      }
    }

    final probs = List<double>.filled(count, 0);
    final aliases = List<int>.filled(count, 0);

    while (small.isNotEmpty && large.isNotEmpty) {
      final a = small.removeLast();
      final g = large.removeLast();
      probs[a] = w[a];
      aliases[a] = g;
      w[g] += w[a] - 1.0;
      if (w[g] < 1.0) {
        small.add(g);
      } else {
        large.add(g);
      }
    }
    while (large.isNotEmpty) {
      probs[large.removeLast()] = 1.0;
    }
    while (small.isNotEmpty) {
      probs[small.removeLast()] = 1.0;
    }

    return VoseSampler._(aliases, probs);
  }

  /// Draws a weighted index in `0..weights.length`, consuming two
  /// pseudo-random doubles from [rng] — the reference's `Weighted::next`.
  int next(Xoshiro256 rng) {
    final r1 = rng.nextDouble();
    final r2 = rng.nextDouble();
    final i = (_probs.length * r1).toInt();
    return r2 < _probs[i] ? i : _aliases[i];
  }
}
