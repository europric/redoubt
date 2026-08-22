/// SHA-256-seeded xoshiro256** PRNG, faithfully ported from the reference
/// BC-UR "multi-part" fountain encoder (crates.io `ur` v0.5.2, MIT/Apache
/// — a public third-party dependency, safe to reference for interop)
/// `src/xoshiro.rs`, plus [chooseFragmentIndexes], ported from that
/// crate's `src/fountain.rs` `choose_fragments`.
///
/// This is the piece that makes fragment-index selection for XOR-"mixed"
/// multi-part QR frames interoperable with real BC-UR senders/receivers
/// (MetaMask, hardware wallets). Those indexes are never transmitted on
/// the wire — only `sequence`/`sequenceCount`/`messageLength`/`checksum`/
/// `data` are — so a receiver MUST independently recompute the exact same
/// pseudo-random index sequence the sender used, or reconstruction of any
/// message that needed a mixed frame silently fails.
///
/// Verified bit-for-bit against the reference crate's own committed
/// golden test vectors: see `test/core/ur/xoshiro256_test.dart`,
/// `test/core/ur/vose_sampler_test.dart`, and
/// `test/core/ur/choose_fragment_indexes_test.dart`.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'vose_sampler.dart';

/// SHA-256-seeded xoshiro256** PRNG.
///
/// Dart's native `int` is a 64-bit two's-complement value on the VM/AOT
/// runtimes this app targets, with silent wraparound on overflow for `+`,
/// `-`, and `*` — matching Rust's `wrapping_*` arithmetic used by the
/// reference implementation. The unsigned right-shift operator `>>>` is
/// used wherever the reference treats a value as an *unsigned* `u64`
/// (rotations, and extracting the top bits for [nextDouble]).
class Xoshiro256 {
  final List<int> _s;

  Xoshiro256._(this._s);

  /// Seeds the generator from the SHA-256 digest of [seed]: each of the
  /// digest's four 8-byte chunks becomes one big-endian `u64` state word,
  /// in order. This matches the reference's `Xoshiro256: From<[u8; 32]>`
  /// composed with `From<&[u8]>` (which SHA-256-hashes the input first).
  factory Xoshiro256.fromSeedBytes(List<int> seed) {
    final digest = sha256.convert(seed).bytes;
    final state = List<int>.filled(4, 0);
    for (var word = 0; word < 4; word++) {
      var v = 0;
      for (var byteIndex = 0; byteIndex < 8; byteIndex++) {
        v = (v << 8) | (digest[8 * word + byteIndex] & 0xFF);
      }
      state[word] = v;
    }
    return Xoshiro256._(state);
  }

  static int _rotl(int x, int k) => (x << k) | (x >>> (64 - k));

  /// Returns the next raw 64-bit xoshiro256** output (as a Dart `int` bit
  /// pattern — treat as unsigned) and advances the generator state, per
  /// the reference's `next_u64`/`try_next_u64`.
  int next() {
    final result = _rotl(_s[1] * 5, 7) * 9;
    final t = _s[1] << 17;
    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2];
    _s[0] ^= _s[3];
    _s[2] ^= t;
    _s[3] = _rotl(_s[3], 45);
    return result;
  }

  /// A pseudo-random double in `[0, 1)`, derived from the top 53 bits of
  /// [next] — the reference's `next_double`/`unit_interval`.
  double nextDouble() {
    const scale = 1.0 / 9007199254740992.0; // 1 / 2^53
    return (next() >>> 11).toDouble() * scale;
  }

  /// A pseudo-random integer in the inclusive range `[low, high]` — the
  /// reference's `next_int`.
  int nextInt(int low, int high) => (nextDouble() * (high - low + 1)).toInt() + low;

  /// Draws [count] items from [items] without replacement, in the order
  /// the generator selects them — the reference's `shuffled`.
  List<T> shuffled<T>(List<T> items, int count) {
    assert(count <= items.length);
    final remaining = List<T>.of(items);
    final result = <T>[];
    while (result.length < count) {
      final index = nextInt(0, remaining.length - 1);
      result.add(remaining.removeAt(index));
    }
    return result;
  }

  /// Samples a degree in `1..=length`, weighted so smaller degrees are
  /// more likely (weight `1/d` for degree `d`), via a Vose alias sampler —
  /// the reference's `choose_degree`.
  int chooseDegree(int length) {
    final weights = List<double>.generate(length, (i) => 1.0 / (i + 1));
    final sampler = VoseSampler(weights);
    return sampler.next(this) + 1;
  }
}

/// Deterministically selects which message-fragment indexes the fountain
/// part with the given [sequence] number mixes, given the total
/// [fragmentCount] and the message's [checksum]. `sequence` is 1-based:
/// `sequence <= fragmentCount` selects the single "pure" fragment
/// `sequence - 1`; `sequence > fragmentCount` is an XOR-"mixed" part whose
/// index set is derived from an `Xoshiro256` seeded by `sequence` and
/// `checksum` (each as 4 big-endian bytes, concatenated). Matches the
/// reference crate's `choose_fragments` exactly.
List<int> chooseFragmentIndexes(int sequence, int fragmentCount, int checksum) {
  if (sequence <= fragmentCount) {
    return [sequence - 1];
  }
  final seed = ByteData(8)
    ..setUint32(0, sequence, Endian.big)
    ..setUint32(4, checksum, Endian.big);
  final rng = Xoshiro256.fromSeedBytes(seed.buffer.asUint8List());
  final degree = rng.chooseDegree(fragmentCount);
  final indexes = List<int>.generate(fragmentCount, (i) => i);
  return rng.shuffled(indexes, degree);
}
