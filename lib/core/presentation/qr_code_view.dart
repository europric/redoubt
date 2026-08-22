/// Thin wrapper over `qr_flutter`'s `QrImageView` (design.md D9) — the sole
/// designated gateway for the `qr_flutter` package (R5). Every feature
/// presentation file renders QR codes through this widget instead of
/// importing `qr_flutter` directly.
///
/// **`qrKey` is forwarded to the inner `QrImageView`, not applied to this
/// wrapper itself.** `account_page_test.dart` and `signature_qr_page_test.dart`
/// look up/type-check the actual `QrImageView` by key/type
/// (`tester.widget<QrImageView>(find.byKey(...))`, `find.byType(QrImageView)`)
/// — keying the wrapper instead would make those finders fail, forcing a
/// test-assertion change that is out of this change's scope. Making this
/// widget a transparent pass-through keeps every existing finder working
/// unchanged.
library;

import 'package:flutter/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    this.qrKey,
    required this.data,
    this.size,
    this.semanticsLabel = 'qr code',
  });

  /// Forwarded to the inner [QrImageView] — see the class doc comment.
  final Key? qrKey;

  final String data;
  final double? size;

  /// Nullable to match [QrImageView]'s own field, but defaulted to the same
  /// `'qr code'` value `QrImageView` itself defaults to — call sites that
  /// omit this (e.g. `signature_qr_page.dart`) must keep rendering the same
  /// semantics label they do today (zero behavior change).
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      key: qrKey,
      data: data,
      size: size,
      // `QrImageView.semanticsLabel` is non-nullable (defaults to
      // `'qr code'`); `??` here preserves that default for a caller that
      // explicitly passes `null`, without forcing this wrapper's own field
      // to be non-nullable.
      semanticsLabel: semanticsLabel ?? 'qr code',
    );
  }
}
