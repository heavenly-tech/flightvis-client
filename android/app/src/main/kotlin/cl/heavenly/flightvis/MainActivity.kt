package cl.heavenly.flightvis

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cl.heavenly.flightvis/tracking")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleCheckinExpiryStop" -> {
                        val expiresAtMs = (call.arguments as Number).toLong()
                        scheduleCheckinExpiryStop(expiresAtMs)
                        result.success(null)
                    }
                    "cancelCheckinExpiryStop" -> {
                        cancelCheckinExpiryStop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun scheduleCheckinExpiryStop(expiresAtMs: Long) {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent =
            Intent(this, CheckinExpiryStopReceiver::class.java).apply {
                action = CheckinExpiryStopReceiver.ACTION_STOP
            }
        val pending =
            PendingIntent.getBroadcast(
                this,
                CHECKIN_EXPIRY_ALARM_REQUEST,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiresAtMs, pending)
    }

    private fun cancelCheckinExpiryStop() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent =
            Intent(this, CheckinExpiryStopReceiver::class.java).apply {
                action = CheckinExpiryStopReceiver.ACTION_STOP
            }
        val pending =
            PendingIntent.getBroadcast(
                this,
                CHECKIN_EXPIRY_ALARM_REQUEST,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        alarmManager.cancel(pending)
    }

    private fun captureLaunchIntent(intent: Intent?) {
        if (intent == null) return
        if (Intent.ACTION_VIEW != intent.action) return
        val data = intent.data ?: return
        val host = data.host?.lowercase() ?: return
        if (host != PRODUCTION_HOST && !host.endsWith(".$PRODUCTION_HOST")) return
        val scheme = data.scheme ?: return
        if (scheme != "https" && scheme != "http") return
        launchUri = data.toString()
    }

    companion object {
        private const val PRODUCTION_HOST = "flight.heavenly.cl"
        private const val CHECKIN_EXPIRY_ALARM_REQUEST = 41001
    }
}