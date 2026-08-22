package dev.carf.redoubt

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Extends [FlutterFragmentActivity] (not [FlutterActivity]) because
/// `local_auth`'s Android implementation requires a `FragmentActivity` host
/// for its biometric prompt (see design.md's "Secure Storage Design" /
/// biometric gate gotcha).
class MainActivity : FlutterFragmentActivity() {
    private val screenChannelName = "vault/screen"

    /// Registers the `vault/screen` method channel backing
    /// `lib/core/security/screen_protection.dart`. Owned, ~15-line native
    /// handler per design.md's Exposure Protection section — deliberately
    /// not a third-party plugin.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            screenChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setFlags" -> {
                    window.setFlags(
                        WindowManager.LayoutParams.FLAG_SECURE,
                        WindowManager.LayoutParams.FLAG_SECURE,
                    )
                    result.success(null)
                }
                "clearFlags" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
