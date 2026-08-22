/// Public API of the `signing` feature. Imported ONLY from outside
/// `lib/features/signing/` — files inside import siblings relatively.
library;

export 'data/eth_transaction_signer.dart';
export 'data/mobile_scanner_frame_source.dart';
export 'domain/committed_address_source.dart';
export 'domain/qr_frame_source.dart';
export 'domain/sign_request.dart';
export 'domain/signed_result.dart';
export 'domain/transaction_signer.dart';
export 'presentation/scan_controller.dart';
export 'presentation/scan_page.dart';
export 'presentation/sign_review_controller.dart';
export 'presentation/sign_review_page.dart';
export 'presentation/signature_qr.dart';
export 'presentation/signature_qr_page.dart';
