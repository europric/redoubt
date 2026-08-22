import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart' hide Mnemonic;
import 'package:redoubt/core/bip39/bip39.dart';
import 'package:redoubt/core/eth/eth.dart';
import 'package:unorm_dart/unorm_dart.dart' show nfkd;

import '../domain/mnemonic.dart';
import '../domain/mnemonic_service.dart';

/// [MnemonicService] backed by `blockchain_utils`'s BIP-39 implementation
/// (the locked crypto-stack decision, design.md's "Ethereum crypto stack"
/// section — already a dependency since PR2).
///
/// **NFKD + real language capture (bip39-nfkd-normalization PR3, design.md's
/// "Normalize at two chokepoints" decision + D5)**: [isValid] and
/// [fromPhrase] both NFKD-normalize the entered phrase text BEFORE it
/// reaches the decoder/validator — the only place typed phrase text meets a
/// wordlist — so precomposed (NFC) input (accents, Hangul syllables typed
/// normally on a keyboard) matches `blockchain_utils`'s already-decomposed
/// non-English wordlists. The matched language rides out on the returned
/// [Mnemonic] via `_decoder.findLanguage(mn).$2` (`Bip39MnemonicDecoder`'s
/// wordlist-detection path — see [_decoder]'s doc comment for why it is
/// constructed with no fixed language). [generate] is unchanged and always
/// returns English (confirmed decision B — generation stays English-only).
/// [fromEntropy] takes a required [MnemonicLanguage] parameter, because
/// re-encoding entropy back into words is the one direction that cannot
/// infer which wordlist to use.
class Bip39MnemonicService implements MnemonicService {
  final Bip39MnemonicGenerator _generator = Bip39MnemonicGenerator();

  /// Constructed with NO fixed language (`Bip39MnemonicDecoder()`, not
  /// `Bip39MnemonicDecoder(someLanguage)`): per `MnemonicDecoderBase
  /// .findLanguage`, an unset `language` makes every `decode`/`findLanguage`
  /// call search across `Bip39Languages.values` and return whichever
  /// wordlist actually matches every word — this IS the language-detection
  /// this class relies on, not an omission.
  final Bip39MnemonicDecoder _decoder = Bip39MnemonicDecoder();
  final Bip39MnemonicValidator _validator = Bip39MnemonicValidator();

  @override
  Mnemonic generate() {
    final generated = _generator.fromWordsNumber(Bip39WordsNum.wordsNum24);
    return _toDomain(generated.toStr());
  }

  @override
  bool isValid(String phrase) => _validator.isValid(nfkd(phrase.trim()));

  @override
  Mnemonic fromPhrase(String phrase) => _toDomain(phrase.trim());

  @override
  Mnemonic fromEntropy(
    Uint8List entropy, {
    required MnemonicLanguage language,
  }) {
    final encoded = Bip39MnemonicEncoder(
      bip39LanguageOf(language),
    ).encode(entropy);
    return Mnemonic(
      words: encoded.toList(),
      entropy: Uint8List.fromList(entropy),
      language: language,
    );
  }

  Mnemonic _toDomain(String phrase) {
    final normalized = nfkd(phrase);
    final mn = Bip39Mnemonic.fromString(normalized);
    final matchedLanguage = mnemonicLanguageOf(_decoder.findLanguage(mn).$2);
    final entropyBytes = _decoder.decode(normalized);
    return Mnemonic(
      words: mn.toList(),
      entropy: Uint8List.fromList(entropyBytes),
      language: matchedLanguage,
    );
  }
}
