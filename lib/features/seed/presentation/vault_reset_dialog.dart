import 'package:flutter/material.dart';

/// Shows the delete-account confirmation dialog (`account-deletion` spec's
/// "Confirmation Dialog Warns Of Irreversibility Before PIN Entry"
/// requirement) and resolves to whether the user confirmed.
///
/// Returns `true` only when Delete is tapped; `false` for Cancel or any
/// other dismissal (barrier tap, back gesture). Declining leaves all
/// account state untouched -- this function itself never touches storage;
/// the caller (`app_router.dart`'s `/account/delete/pin` route) is the one
/// that pushes to the PIN-gated wipe step, only when this returns `true`.
///
/// A plain Cancel/Delete `AlertDialog` -- deliberately NOT a "type to
/// confirm" text-input step (explicit product decision, delete-account-
/// secure-wipe design.md).
Future<bool> showVaultResetConfirmation(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete Account?'),
      content: const Text(
        'This permanently deletes your recovery phrase and all account '
        'data from this device. Without your written-down recovery '
        'phrase, any funds in this account will be unrecoverable. '
        'This action cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  return confirmed ?? false;
}
