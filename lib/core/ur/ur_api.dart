/// Public API of the `core/ur` module. Imported ONLY from outside
/// `lib/core/ur/` — files inside import siblings relatively.
///
/// Named `ur_api.dart` rather than `ur.dart` (design.md D12) because
/// `core/ur/ur.dart` already exists as a real, non-barrel library.
library;

export 'bytewords.dart';
export 'crc32.dart';
export 'fountain.dart';
export 'registry/crypto_hdkey.dart';
export 'registry/crypto_keypath.dart';
export 'registry/eth_sign_request.dart';
export 'registry/eth_signature.dart';
export 'registry/uuid.dart';
export 'ur.dart';
export 'vose_sampler.dart';
export 'xoshiro256.dart';
