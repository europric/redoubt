import 'package:flutter/foundation.dart';

import '../domain/mnemonic.dart';
import '../domain/mnemonic_service.dart';

/// Owns the "generate a new mnemonic" step of the seed lifecycle.
///
/// Deliberately holds NO persistence dependency (no `SecureSeedRepository`)
/// — this is the structural guarantee that a generated-but-not-yet-verified
/// mnemonic can never be written to storage from this screen, matching
/// `seed-lifecycle` spec's "Regeneration produces a fresh phrase" scenario.
/// Persistence happens later, in [SeedVerifyController], only after correct
/// re-entry.
class SeedGenerateController extends ChangeNotifier {
  SeedGenerateController({required this.mnemonicService});

  final MnemonicService mnemonicService;

  Mnemonic? _mnemonic;

  /// The most recently generated mnemonic, or `null` before the first
  /// [generate] call.
  Mnemonic? get mnemonic => _mnemonic;

  /// Generates a fresh mnemonic, discarding any previously generated one.
  /// Calling this again ("regenerate") never persists the discarded phrase
  /// — there is no repository this controller could persist it to.
  void generate() {
    _mnemonic = mnemonicService.generate();
    notifyListeners();
  }

  /// Zeroizes the held mnemonic's entropy buffer before this controller is
  /// discarded (#30, `seed-exposure-protection` spec) — a generated
  /// mnemonic must not linger in memory once its owning screen is gone.
  @override
  void dispose() {
    _mnemonic?.zeroize();
    super.dispose();
  }
}
