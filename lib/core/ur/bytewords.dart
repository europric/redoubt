/// Bytewords minimal-style codec per BCR-2020-012 ("Bytewords: Encoding
/// binary data as English words").
///
/// Minimal encoding represents each byte as the first and last letter of
/// its corresponding word in the 256-word dictionary below (2 ASCII chars
/// per byte — as dense as hex, less error-prone to transcribe). A 4-byte,
/// big-endian CRC-32 checksum of the payload is appended before encoding,
/// per the spec's "Checksum" section.
library;

import 'dart:typed_data';

import 'crc32.dart';

/// Thrown when [decodeMinimal] is given input that is not valid minimal
/// Bytewords: wrong length, an unrecognized 2-letter code, or a checksum
/// that does not match the decoded payload.
class BytewordsDecodeException implements Exception {
  final String message;
  BytewordsDecodeException(this.message);

  @override
  String toString() => 'BytewordsDecodeException: $message';
}

/// The 256-word Bytewords dictionary, indexed by byte value (0x00-0xFF),
/// as published in BCR-2020-012's "Word List" section.
const List<String> wordList = [
  'able', 'acid', 'also', 'apex', 'aqua', 'arch', 'atom', 'aunt', //
  'away', 'axis', 'back', 'bald', 'barn', 'belt', 'beta', 'bias', //
  'blue', 'body', 'brag', 'brew', 'bulb', 'buzz', 'calm', 'cash', //
  'cats', 'chef', 'city', 'claw', 'code', 'cola', 'cook', 'cost', //
  'crux', 'curl', 'cusp', 'cyan', 'dark', 'data', 'days', 'deli', //
  'dice', 'diet', 'door', 'down', 'draw', 'drop', 'drum', 'dull', //
  'duty', 'each', 'easy', 'echo', 'edge', 'epic', 'even', 'exam', //
  'exit', 'eyes', 'fact', 'fair', 'fern', 'figs', 'film', 'fish', //
  'fizz', 'flap', 'flew', 'flux', 'foxy', 'free', 'frog', 'fuel', //
  'fund', 'gala', 'game', 'gear', 'gems', 'gift', 'girl', 'glow', //
  'good', 'gray', 'grim', 'guru', 'gush', 'gyro', 'half', 'hang', //
  'hard', 'hawk', 'heat', 'help', 'high', 'hill', 'holy', 'hope', //
  'horn', 'huts', 'iced', 'idea', 'idle', 'inch', 'inky', 'into', //
  'iris', 'iron', 'item', 'jade', 'jazz', 'join', 'jolt', 'jowl', //
  'judo', 'jugs', 'jump', 'junk', 'jury', 'keep', 'keno', 'kept', //
  'keys', 'kick', 'kiln', 'king', 'kite', 'kiwi', 'knob', 'lamb', //
  'lava', 'lazy', 'leaf', 'legs', 'liar', 'limp', 'lion', 'list', //
  'logo', 'loud', 'love', 'luau', 'luck', 'lung', 'main', 'many', //
  'math', 'maze', 'memo', 'menu', 'meow', 'mild', 'mint', 'miss', //
  'monk', 'nail', 'navy', 'need', 'news', 'next', 'noon', 'note', //
  'numb', 'obey', 'oboe', 'omit', 'onyx', 'open', 'oval', 'owls', //
  'paid', 'part', 'peck', 'play', 'plus', 'poem', 'pool', 'pose', //
  'puff', 'puma', 'purr', 'quad', 'quiz', 'race', 'ramp', 'real', //
  'redo', 'rich', 'road', 'rock', 'roof', 'ruby', 'ruin', 'runs', //
  'rust', 'safe', 'saga', 'scar', 'sets', 'silk', 'skew', 'slot', //
  'soap', 'solo', 'song', 'stub', 'surf', 'swan', 'taco', 'task', //
  'taxi', 'tent', 'tied', 'time', 'tiny', 'toil', 'tomb', 'toys', //
  'trip', 'tuna', 'twin', 'ugly', 'undo', 'unit', 'urge', 'user', //
  'vast', 'very', 'veto', 'vial', 'vibe', 'view', 'visa', 'void', //
  'vows', 'wall', 'wand', 'warm', 'wasp', 'wave', 'waxy', 'webs', //
  'what', 'when', 'whiz', 'wolf', 'work', 'yank', 'yawn', 'yell', //
  'yoga', 'yurt', 'zaps', 'zero', 'zest', 'zinc', 'zone', 'zoom', //
];

/// Maps a word's first+last letter (the "minimal" 2-char code) to its byte
/// value. Built once; every word's first+last-letter pair is guaranteed
/// unique by the dictionary's word-selection criteria (BCR-2020-012).
final Map<String, int> _minimalIndex = _buildMinimalIndex();

Map<String, int> _buildMinimalIndex() {
  final map = <String, int>{};
  for (var i = 0; i < wordList.length; i++) {
    final word = wordList[i];
    map[word[0] + word[3]] = i;
  }
  return map;
}

/// Encodes [payload] as minimal Bytewords, including its appended 4-byte
/// CRC-32 checksum. Output is lowercase, 2 characters per input+checksum
/// byte.
String encodeMinimal(List<int> payload) {
  final withChecksum = Uint8List(payload.length + 4)
    ..setRange(0, payload.length, payload)
    ..setRange(payload.length, payload.length + 4, crc32Bytes(payload));
  final buffer = StringBuffer();
  for (final byte in withChecksum) {
    final word = wordList[byte];
    buffer
      ..write(word[0])
      ..write(word[3]);
  }
  return buffer.toString();
}

/// Decodes minimal Bytewords [text] (case-insensitive) back to the
/// original payload, verifying the trailing 4-byte CRC-32 checksum.
///
/// Throws [BytewordsDecodeException] for malformed input: odd length, too
/// short to contain a checksum, an unrecognized 2-letter code, or a
/// checksum mismatch — this boundary handles untrusted/attacker-controlled
/// QR input, so it never lets a decode error surface as an uncaught
/// exception type.
Uint8List decodeMinimal(String text) {
  final lower = text.toLowerCase();
  if (lower.length.isOdd) {
    throw BytewordsDecodeException(
      'minimal Bytewords length must be even, got ${lower.length}',
    );
  }
  final byteCount = lower.length ~/ 2;
  if (byteCount < 4) {
    throw BytewordsDecodeException(
      'input too short to contain a 4-byte checksum ($byteCount bytes)',
    );
  }
  final bytes = Uint8List(byteCount);
  for (var i = 0; i < byteCount; i++) {
    final code = lower.substring(i * 2, i * 2 + 2);
    final index = _minimalIndex[code];
    if (index == null) {
      throw BytewordsDecodeException('unknown Bytewords code "$code" at byte $i');
    }
    bytes[i] = index;
  }
  final payload = bytes.sublist(0, byteCount - 4);
  final checksum = bytes.sublist(byteCount - 4);
  final expected = crc32Bytes(payload);
  for (var i = 0; i < 4; i++) {
    if (checksum[i] != expected[i]) {
      throw BytewordsDecodeException('checksum mismatch');
    }
  }
  return payload;
}
