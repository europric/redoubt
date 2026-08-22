/// Public API of the `core/security` module. Imported ONLY from outside
/// `lib/core/security/` — files inside import siblings relatively.
library;

export 'argon2_kdf.dart';
export 'auth_service.dart';
export 'authenticated_seed_repository.dart';
export 'flutter_secure_seed_repository.dart';
export 'fresh_install_gate.dart';
export 'install_marker_store.dart';
export 'screen_capture_monitor.dart';
export 'screen_protection.dart';
export 'sealed_vault_repository.dart';
export 'secure_seed_repository.dart';
export 'unlock_preferences.dart';
export 'unlock_throttle.dart';
export 'vault_blob.dart';
export 'vault_cipher.dart';
export 'vault_plaintext.dart';
export 'vault_state_probe.dart';
export 'vault_wiper.dart';
