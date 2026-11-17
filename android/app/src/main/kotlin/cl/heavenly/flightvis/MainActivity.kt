package cl.heavenly.flightvis

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var launchUri: String? = null

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
                                "extras" to emptyMap<String, String>(),
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

  private fun captureLaunchIntent(intent: Intent?) {
        if (intent == null) return
        if (Intent.ACTION_VIEW != intent.action) return
        val data: Uri? = intent.data ?: return
        val host = data.host?.lowercase() ?: return
        if (host != PRODUCTION_HOST && !host.endsWith(".$PRODUCTION_HOST")) return
        if (data.scheme != "https" && data.scheme != "http") return
        launchUri = data.toString()
    }

    companion object {
        private const val PRODUCTION_HOST = "flight.heavenly.cl"
    }
}