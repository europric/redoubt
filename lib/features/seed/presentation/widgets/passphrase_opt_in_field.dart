/// Shared "Add a passphrase (25th word)" opt-in control (design.md D6,
/// seed-passphrase-25th-word). Hosted on `SeedGeneratePage`/`SeedImportPage`
/// (both with [PassphraseOptInField.requireConfirmation]: `true`) and, in a
/// later PR, `SignReviewPage` (`requireConfirmation`: `false` — D4's "no
/// confirmation field at signing", since the signing-time address-match
/// guard is a strictly stronger verifier than retyping).
///
/// **Unchecked by default** (`critical-screen-ux` spec's "Disclosure-Neutral
/// Passphrase Toggle" requirement): renders only the checkbox row, with no
/// passphrase field visible and no proactive [onChanged] call, until the
/// user checks it. Checking it reveals an obscured passphrase field, an
/// unrecoverable-secret warning, and — only when [requireConfirmation] is
/// `true` — a second confirm field. [onChanged] fires with the UTF-8-encoded
/// bytes only once the current state is valid (checked, non-empty, and
/// matching confirmation when required); any other state (unchecked, empty,
/// or mismatched) fires it with `null`, so hosts can gate their primary
/// action on a single non-null test.
///
/// **Non-ASCII input is accepted (bip39-nfkd-normalization PR3, `seed-
/// passphrase` spec's "Passphrase Is NFKD-Normalized At The Shared
/// Derivation Boundary" requirement)**: this field no longer filters input.
/// The printable-ASCII-only restriction this file previously enforced via a
/// [FilteringTextInputFormatter] is REMOVED — `deriveBip39SeedSync`
/// (`core/eth/bip39_seed.dart`) now NFKD-normalizes the passphrase at the
/// single shared derivation boundary before it becomes the PBKDF2 salt, so
/// the ASCII restriction is no longer necessary and only blocked legitimate
/// non-English passphrases.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class PassphraseOptInField extends StatefulWidget {
  const PassphraseOptInField({
    super.key,
    required this.requireConfirmation,
    required this.onChanged,
  });

  /// Whether a second confirm field is shown and must match the passphrase
  /// field before a value is reported. `true` on generate/import, `false`
  /// on sign (D4).
  final bool requireConfirmation;

  /// Called with the UTF-8-encoded passphrase bytes once the current state
  /// is valid, or `null` while unchecked, empty, or (when
  /// [requireConfirmation] is `true`) mismatched.
  final ValueChanged<Uint8List?> onChanged;

  @override
  State<PassphraseOptInField> createState() => _PassphraseOptInFieldState();
}

class _PassphraseOptInFieldState extends State<PassphraseOptInField> {
  bool _enabled = false;
  final _passphraseField = TextEditingController();
  final _confirmField = TextEditingController();

  @override
  void initState() {
    super.initState();
    _passphraseField.addListener(_notify);
    _confirmField.addListener(_notify);
  }

  @override
  void dispose() {
    _passphraseField.dispose();
    _confirmField.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged(_currentValue());

  Uint8List? _currentValue() {
    if (!_enabled) return null;
    final passphrase = _passphraseField.text;
    if (passphrase.isEmpty) return null;
    if (widget.requireConfirmation && passphrase != _confirmField.text) {
      return null;
    }
    return Uint8List.fromList(utf8.encode(passphrase));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          key: const Key('passphraseOptInCheckbox'),
          value: _enabled,
          title: const Text('Add a passphrase (25th word)'),
          onChanged: (value) {
            setState(() => _enabled = value ?? false);
            widget.onChanged(_currentValue());
          },
        ),
        if (_enabled) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'This passphrase is never stored. If you forget it, funds '
              'protected by it are permanently unrecoverable. Non-Latin '
              'characters need hardware-wallet BIP-39 support to recover.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('passphraseField'),
              controller: _passphraseField,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Passphrase'),
            ),
          ),
          if (widget.requireConfirmation)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: TextField(
                key: const Key('passphraseConfirmField'),
                controller: _confirmField,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm passphrase',
                ),
              ),
            ),
        ],
      ],
    );
  }
}
