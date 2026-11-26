package cl.heavenly.flightvis

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
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
                        try {
                            scheduleCheckinExpiryStop(expiresAtMs)
                        } catch (e: Exception) {
                            Log.w(TAG, "scheduleCheckinExpiryStop failed", e)
                        }
                        result.success(null)
                    }
                    "cancelCheckinExpiryStop" -> {
                        cancelCheckinExpiryStop()
                        result.success(null)
                    }
                    "startLocalFixRecorder" -> {
                        LocalPositionRecorder.startObserving()
                        result.success(null)
                    }
                    "getRecentPositions" -> {
                        result.success(LocalPositionRecorder.snapshot())
                    }
                    "clearRecentPositions" -> {
                        LocalPositionRecorder.clear()
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "openBatteryOptimizationSettings" -> {
                        result.success(openBatteryOptimizationSettings())
                    }
                    "getLastKnownLocation" -> {
                        result.success(getLastKnownLocationMap())
                    }
                    "startLocalFlightRecording" -> {
                        startLocalFlightRecording(result)
                    }
                    "stopLocalFlightRecording" -> {
                        result.success(stopLocalFlightRecording())
                    }
                    "isLocalFlightRecording" -> {
                        result.success(LocalFlightRecorderService.isRecording)
                    }
                    "getLocalFlightPositions" -> {
                        result.success(LocalFlightRecorderService.snapshotFixes())
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "cl.heavenly.flightvis/tracking_positions",
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    events: EventChannel.EventSink?,
                ) {
                    LocalPositionRecorder.setSink(events)
                    if (!LocalFlightRecorderService.isRecording) {
                        LocalPositionRecorder.startObserving()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    LocalPositionRecorder.setSink(null)
                }
            },
        )
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            pm?.isIgnoringBatteryOptimizations(packageName) ?: false
        } catch (e: Exception) {
            Log.w(TAG, "isIgnoringBatteryOptimizations failed", e)
            false
        }
    }

    private fun openBatteryOptimizationSettings(): String {
        val packageUri = Uri.parse("package:$packageName")

        // 1. Direct per-app exemption dialog (requires REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val requestIntent =
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri)
            if (tryStartActivity(requestIntent, "request_ignore_battery_optimizations")) {
                return "request_ignore_battery_optimizations"
            }

            // 2. General battery optimization list settings.
            val listIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            if (tryStartActivity(listIntent, "ignore_battery_optimization_settings")) {
                return "ignore_battery_optimization_settings"
            }
        }

        // 3. App details settings screen.
        val detailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
        if (tryStartActivity(detailsIntent, "application_details_settings")) {
            return "application_details_settings"
        }

        return "none"
    }

    private fun tryStartActivity(intent: Intent, label: String): Boolean {
        return try {
            if (intent.resolveActivity(packageManager) == null) {
                Log.w(TAG, "No activity resolved for $label")
                return false
            }
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "ActivityNotFoundException for $label", e)
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "SecurityException for $label", e)
            false
        } catch (e: Exception) {
            Log.w(TAG, "Unexpected exception for $label", e)
            false
        }
    }

    private fun hasAnyLocationPermission(): Boolean {
        val fine =
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        val coarse =
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun getLastKnownLocationMap(): Map<String, Any?>? {
        if (!hasAnyLocationPermission()) return null
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null

        val providers = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            providers.add(LocationManager.FUSED_PROVIDER)
        }
        providers.add(LocationManager.GPS_PROVIDER)
        providers.add(LocationManager.NETWORK_PROVIDER)

        var best: Location? = null
        for (provider in providers) {
            val loc =
                try {
                    if (lm.allProviders.contains(provider)) {
                        lm.getLastKnownLocation(provider)
                    } else {
                        null
                    }
                } catch (_: SecurityException) {
                    null
                } catch (_: IllegalArgumentException) {
                    null
                } catch (_: Exception) {
                    null
                } ?: continue

            if (!loc.latitude.isFinite() || !loc.longitude.isFinite()) continue
            if (loc.latitude < -90.0 || loc.latitude > 90.0 ||
                loc.longitude < -180.0 || loc.longitude > 180.0
            ) {
                continue
            }

            if (best == null || isBetterLocation(loc, best)) {
                best = loc
            }
        }

        val chosen = best ?: return null
        return mapOf(
            "timeMs" to (if (chosen.time > 0L) chosen.time else System.currentTimeMillis()),
            "lat" to chosen.latitude,
            "lon" to chosen.longitude,
            "alt" to (if (chosen.hasAltitude() && chosen.altitude.isFinite()) chosen.altitude else null),
            "bearing" to (if (chosen.hasBearing() && chosen.bearing.isFinite()) chosen.bearing.toDouble() else null),
            "speed" to (if (chosen.hasSpeed() && chosen.speed.isFinite()) chosen.speed.toDouble() else null),
        )
    }

    private fun isBetterLocation(candidate: Location, current: Location): Boolean {
        val timeDelta = candidate.time - current.time
        if (timeDelta > 60_000L) return true
        if (timeDelta < -60_000L) return false
        val candidateAcc = if (candidate.hasAccuracy()) candidate.accuracy else Float.MAX_VALUE
        val currentAcc = if (current.hasAccuracy()) current.accuracy else Float.MAX_VALUE
        return candidateAcc < currentAcc
    }

    private fun startLocalFlightRecording(result: MethodChannel.Result) {
        if (!hasAnyLocationPermission()) {
            result.error("permission_denied", "Location permission required", null)
            return
        }
        LocalPositionRecorder.clear()
        LocalFlightRecorderService.clearFixes()
        val intent =
            Intent(this, LocalFlightRecorderService::class.java).apply {
                action = LocalFlightRecorderService.ACTION_START
            }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(true)
        } catch (e: Exception) {
            Log.w(TAG, "startLocalFlightRecording failed", e)
            result.success(false)
        }
    }

    private fun stopLocalFlightRecording(): List<Map<String, Any?>> {
        val snapshot = LocalFlightRecorderService.snapshotFixes()
        try {
            val stopIntent =
                Intent(this, LocalFlightRecorderService::class.java).apply {
                    action = LocalFlightRecorderService.ACTION_STOP
                }
            stopService(stopIntent)
        } catch (e: Exception) {
            Log.w(TAG, "stopLocalFlightRecording failed", e)
        }
        LocalFlightRecorderService.clearFixes()
        LocalPositionRecorder.clear()
        return snapshot
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
        try {
            val useExact =
                Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                    alarmManager.canScheduleExactAlarms()
            if (useExact) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    expiresAtMs,
                    pending,
                )
            } else {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiresAtMs, pending)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "exact alarm denied; falling back to inexact", e)
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiresAtMs, pending)
        }
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
        private const val TAG = "FlightVisMainActivity"
    }
}
