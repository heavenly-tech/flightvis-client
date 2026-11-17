package cl.heavenly.flightvis

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var launchUri: String? = null
    private var launchExtras: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        captureLaunchIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureLaunchIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cl.heavenly.flightvis/deeplink")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getLaunchDeepLink" -> {
                        result.success(
                            mapOf(
                                "uri" to (launchUri ?: ""),
                                "extras" to (launchExtras ?: emptyMap<String, String>()),
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun captureLaunchIntent(intent: Intent?) {
        if (intent == null) return
        val data: Uri? = intent.data
        launchUri = data?.toString()
        val extras = mutableMapOf<String, String>()
        for (key in listOf("slug", "club_slug", "clubSlug", "token", "checkin_token", "checkinToken", "magic_token", "magicToken")) {
            intent.getStringExtra(key)?.let { if (it.isNotBlank()) extras[key] = it }
        }
        if (extras.isNotEmpty()) launchExtras = extras
    }
}