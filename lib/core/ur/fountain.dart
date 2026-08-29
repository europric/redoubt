/// Multi-part BC-UR fountain codec (message-splitting + XOR-mixed
/// fragments) — the multi-part half of BCR-2020-005.
///
/// **Compatibility note**: fragment-index selection for XOR-"mixed" parts
/// (`_fragmentIndexesFor`, via [chooseFragmentIndexes]) is a faithful,
/// bit-for-bit port of the reference BC-UR SHA-256-seeded
/// Xoshiro256**-plus-Vose-alias-sampler algorithm used by real hardware
/// wallets and MetaMask Extension, verified against that reference
/// implementation's own golden test vectors — see
/// `test/core/ur/xoshiro256_test.dart`, `test/core/ur/vose_sampler_test.dart`,
/// and `test/core/ur/choose_fragment_indexes_test.dart`. This matters
/// because those indexes are never transmitted on the wire (only
/// sequence/seqCount/messageLen/checksum/data are), so a receiver that
/// derived a different index set than the sender used would silently fail
/// to reconstruct any message that needed a mixed frame — which real
/// camera-scanned animated QR routinely does whenever any pure frame is
/// missed.
library;

import 'dart:typed_data';

import 'crc32.dart';
import 'xoshiro256.dart' show chooseFragmentIndexes;

/// Thrown for malformed or inconsistent fountain input: a fragment that
/// disagrees with previously-received parts, an oversized fragment, an
/// invalid `seqNum`, a declared `messageLength` outside the reassemblable
/// range, or a reassembled message that fails its declared checksum. QR
/// payloads are attacker-controllable, so this boundary never lets a
/// decode problem surface as an uncaught exception.
class FountainDecodeException implements Exception {
  final String message;
  FountainDecodeException(this.message);

  @override
  String toString() => 'FountainDecodeException: $message';
}

/// A defensive upper bound on a single fragment's size. Real QR-carried
/// fragments are at most a few KB; anything near this bound is either a
/// bug or a hostile payload trying to force excessive allocation.
const int maxReasonableFragmentLength = 1 << 20; // 1 MiB
const int maxReasonableSeqLen = 500; // ~500 fragments max — real Ethereum UR messages use <50

/// One part of a multi-part BC-UR message.
///
/// `seqNum` is 1-based. Parts with `seqNum <= seqLen` are "pure" (carry
/// exactly one message fragment); parts with `seqNum > seqLen` are
/// "mixed" (carry the XOR of >=2 fragments), per BCR-2020-005's fountain
/// scheme.
class FountainPart {
  final int seqNum;
  final int seqLen;
  final int messageLength;
  final int checksum;
  final Uint8List fragment;

  FountainPart({
    required this.seqNum,
    required this.seqLen,
    required this.messageLength,
    required this.checksum,
    required this.fragment,
  });
}

/// Splits [message] into fixed-size fragments no larger than
/// [maxFragmentLength] and encodes it as a sequence of fountain parts.
///
/// The first `fragmentCount` parts (where `fragmentCount =
/// ceil(message.length / maxFragmentLength)`) are "pure" — one fragment
/// each, `seqNum` 1..fragmentCount. If [partCount] is provided and greater
/// than `fragmentCount`, additional "mixed" parts (`seqNum >
/// fragmentCount`) are generated as deterministic XOR combinations of >=2
/// fragments.
List<FountainPart> encode(
  Uint8List message, {
  required int maxFragmentLength,
  int? partCount,
}) {
  if (maxFragmentLength <= 0) {
    throw ArgumentError.value(maxFragmentLength, 'maxFragmentLength', 'must be > 0');
  }
  final fragmentCount = message.isEmpty
      ? 1
      : (message.length / maxFragmentLength).ceil();
  final fragmentLength = (message.length / fragmentCount).ceil();
  final fragments = <Uint8List>[];
  for (var i = 0; i < fragmentCount; i++) {
    final start = i * fragmentLength;
    final end = (start + fragmentLength).clamp(0, message.length);
    final frag = Uint8List(fragmentLength);
    if (start < message.length) {
      frag.setRange(0, end - start, message.sublist(start, end));
    }
    fragments.add(frag);
  }
  final checksum = crc32(message);
  final total = partCount ?? fragmentCount;
  if (total < fragmentCount) {
    throw ArgumentError.value(
      partCount,
      'partCount',
      'must be >= fragment count ($fragmentCount)',
    );
  }
  final parts = <FountainPart>[];
  for (var seqNum = 1; seqNum <= total; seqNum++) {
    final indexes = _fragmentIndexesFor(seqNum, fragmentCount, checksum);
    final mixed = Uint8List(fragmentLength);
    for (final idx in indexes) {
      final frag = fragments[idx];
      for (var b = 0; b < fragmentLength; b++) {
        mixed[b] ^= frag[b];
      }
    }
    parts.add(
      FountainPart(
        seqNum: seqNum,
        seqLen: fragmentCount,
        messageLength: message.length,
        checksum: checksum,
        fragment: mixed,
      ),
    );
  }
  return parts;
}

/// Deterministically selects which fragment indexes a given part mixes.
/// Pure parts (`seqNum <= seqLen`) always map to a single fragment. Mixed
/// parts delegate to [chooseFragmentIndexes], the bit-for-bit port of the
/// reference BC-UR fragment-selection algorithm (see this file's
/// "Compatibility note" doc comment above).
List<int> _fragmentIndexesFor(int seqNum, int seqLen, int checksum) =>
    chooseFragmentIndexes(seqNum, seqLen, checksum);

class _PendingEquation {
  final Set<int> indexes;
  final Uint8List data;
  _PendingEquation(this.indexes, this.data);
}

/// Incrementally reassembles fountain parts fed via [addPart], in any
/// order, tolerating duplicates. Resolves mixed ("XOR-combined") fragments
/// by reducing each new equation against already-known fragments and
/// cascading: whenever an equation is reduced to exactly one unknown
/// fragment, that fragment is solved and every other pending equation is
/// re-reduced against it.
class FountainDecoder {
  int? _seqLen;
  int? _messageLength;
  int? _checksum;
  int? _fragmentLength;
  List<Uint8List?>? _fragments;
  final List<_PendingEquation> _pending = [];
  int _solvedCount = 0;
  bool _verified = false;

  /// True once every fragment has been solved AND the reassembled message
  /// matches its declared checksum.
  bool get isComplete => _verified;

  /// Adds a received [part].
  ///
  /// Throws [FountainDecodeException] if [part] disagrees with previously
  /// accepted parts (`seqLen`, `messageLength`, checksum, fragment
  /// length), has an invalid `seqNum`, an oversized fragment, a declared
  /// `messageLength` outside the reassemblable range (`1..fragmentLength *
  /// seqLen`), or if — once every fragment is resolved — the reassembled
  /// message fails its declared checksum.
  void addPart(FountainPart part) {
    if (part.seqNum < 1) {
      throw FountainDecodeException('seqNum must be >= 1, got ${part.seqNum}');
    }
    if (part.fragment.length > maxReasonableFragmentLength) {
      throw FountainDecodeException(
        'fragment too large (${part.fragment.length} bytes)',
      );
    }
    if (_seqLen == null) {
      if (part.seqLen > maxReasonableSeqLen) {
        throw FountainDecodeException(
          'seqLen too large (${part.seqLen}) — max $maxReasonableSeqLen',
        );
      }
      if (part.messageLength < 1 ||
          part.messageLength > part.fragment.length * part.seqLen) {
        throw FountainDecodeException(
          'messageLength out of range (${part.messageLength}) — '
          'must be 1..${part.fragment.length * part.seqLen}',
        );
      }
      _seqLen = part.seqLen;
      _messageLength = part.messageLength;
      _checksum = part.checksum;
      _fragmentLength = part.fragment.length;
      _fragments = List<Uint8List?>.filled(part.seqLen, null);
    } else {
      if (part.seqLen != _seqLen) {
        throw FountainDecodeException(
          'inconsistent seqLen: expected $_seqLen, got ${part.seqLen}',
        );
      }
      if (part.messageLength != _messageLength) {
        throw FountainDecodeException(
          'inconsistent messageLength: expected $_messageLength, got ${part.messageLength}',
        );
      }
      if (part.checksum != _checksum) {
        throw FountainDecodeException(
          'inconsistent checksum: expected $_checksum, got ${part.checksum}',
        );
      }
      if (part.fragment.length != _fragmentLength) {
        throw FountainDecodeException(
          'inconsistent fragment length: expected $_fragmentLength, got ${part.fragment.length}',
        );
      }
    }

    final indexes = _fragmentIndexesFor(part.seqNum, _seqLen!, _checksum!).toSet();
    _pending.add(_PendingEquation(indexes, Uint8List.fromList(part.fragment)));
    _cascade();
  }

  void _cascade() {
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (var i = _pending.length - 1; i >= 0; i--) {
        final eq = _pending[i];
        final reduced = Uint8List.fromList(eq.data);
        final remaining = <int>{};
        for (final idx in eq.indexes) {
          final known = _fragments![idx];
          if (known != null) {
            for (var b = 0; b < reduced.length; b++) {
              reduced[b] ^= known[b];
            }
          } else {
            remaining.add(idx);
          }
        }
        if (remaining.isEmpty) {
          _pending.removeAt(i); // fully redundant (duplicate/derivable)
          continue;
        }
        if (remaining.length == 1) {
          final idx = remaining.first;
          if (_fragments![idx] == null) {
            _fragments![idx] = reduced;
            _solvedCount++;
            progressed = true;
          }
          _pending.removeAt(i);
        } else {
          _pending[i] = _PendingEquation(remaining, reduced);
        }
      }
    }
    if (_solvedCount == _seqLen && !_verified) {
      _verifyChecksum();
    }
  }

  void _verifyChecksum() {
    final combined = BytesBuilder();
    for (final frag in _fragments!) {
      combined.add(frag!);
    }
    final full = combined.toBytes();
    final trimmed = Uint8List.sublistView(full, 0, _messageLength!);
    if (crc32(trimmed) != _checksum) {
      throw FountainDecodeException(
        'reassembled message failed its declared checksum',
      );
    }
    _verified = true;
  }

  /// Returns the fully reassembled, checksum-verified message, or `null`
  /// if reassembly is not yet complete.
  Uint8List? get message {
    if (!isComplete) return null;
    final combined = BytesBuilder();
    for (final frag in _fragments!) {
      combined.add(frag!);
    }
    final full = combined.toBytes();
    return Uint8List.sublistView(full, 0, _messageLength!);
  }
}
