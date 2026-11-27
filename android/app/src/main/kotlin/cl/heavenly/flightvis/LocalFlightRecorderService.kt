package cl.heavenly.flightvis

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Purely local foreground location service for non-club / offline flights.
 *
 * Uses Android [LocationManager] directly (no Google Play Services, no Traccar
 * SDK, and zero HTTP / network code) so recorded fixes can never be uploaded.
 */
class LocalFlightRecorderService : Service() {
    private var locationManager: LocationManager? = null
    private var activeListener: LocationListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopRecordingInternal()
            stopSelf()
            return START_NOT_STICKY
        }

        if (!hasLocationPermission(this)) {
            Log.w(TAG, "Refusing to start local recording without location permission")
            isRecording = false
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            ensureNotificationChannel()
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to enter foreground for local flight recording", e)
            isRecording = false
            stopSelf()
            return START_NOT_STICKY
        }

        startLocationUpdates()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopRecordingInternal()
        super.onDestroy()
    }

    private fun startLocationUpdates() {
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            Log.w(TAG, "LocationManager unavailable")
            isRecording = false
            stopSelf()
            return
        }
        stopLocationUpdates()
        locationManager = lm

        val listener =
            object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    handleLocation(location)
                }

                @Deprecated("Deprecated in Android API 29")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                override fun onProviderEnabled(provider: String) {}

                override fun onProviderDisabled(provider: String) {}
            }
        activeListener = listener

        var registeredAny = false
        try {
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.allProviders.contains(LocationManager.GPS_PROVIDER)
            ) {
                lm.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    GPS_MIN_TIME_MS,
                    GPS_MIN_DISTANCE_M,
                    listener,
                    Looper.getMainLooper(),
                )
                registeredAny = true
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "GPS provider permission denied", e)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "GPS provider unavailable", e)
        }

        try {
            if (lm.allProviders.contains(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    NETWORK_MIN_TIME_MS,
                    NETWORK_MIN_DISTANCE_M,
                    listener,
                    Looper.getMainLooper(),
                )
                registeredAny = true
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Network provider permission denied", e)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Network provider unavailable", e)
        }

        if (!registeredAny) {
            Log.w(TAG, "No location providers could be registered for local flight")
            isRecording = false
            stopSelf()
            return
        }

        isRecording = true
    }

    private fun stopLocationUpdates() {
        val lm = locationManager
        val listener = activeListener
        if (lm != null && listener != null) {
            try {
                lm.removeUpdates(listener)
            } catch (e: Exception) {
                Log.w(TAG, "removeUpdates failed", e)
            }
        }
        activeListener = null
    }

    private fun stopRecordingInternal() {
        stopLocationUpdates()
        isRecording = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {
        }
    }

    private fun handleLocation(location: Location) {
        val lat = location.latitude
        val lon = location.longitude
        if (!lat.isFinite() || !lon.isFinite()) return
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) return

        val timeMs = if (location.time > 0L) location.time else System.currentTimeMillis()
        val alt = if (location.hasAltitude() && location.altitude.isFinite()) location.altitude else null
        val bearing =
            if (location.hasBearing() && location.bearing.isFinite()) {
                location.bearing.toDouble()
            } else {
                null
            }
        val speed =
            if (location.hasSpeed() && location.speed.isFinite()) {
                location.speed.toDouble()
            } else {
                null
            }

        appendFlightFix(
            timeMs = timeMs,
            lat = lat,
            lon = lon,
            alt = alt,
            bearing = bearing,
            speed = speed,
        )
        LocalPositionRecorder.recordFix(
            timeMs = timeMs,
            lat = lat,
            lon = lon,
            alt = alt,
            bearing = bearing,
            speed = speed,
        )
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.local_recording_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            )
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openIntent =
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        val contentIntent =
            PendingIntent.getActivity(
                this,
                NOTIFICATION_ID,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

        return builder
            .setSmallIcon(R.drawable.ic_tracker_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.local_recording_notification_text))
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    companion object {
        private const val TAG = "LocalFlightRecorderSvc"
        private const val CHANNEL_ID = "flightvis_local_flight_recording"
        private const val NOTIFICATION_ID = 42002
        private const val GPS_MIN_TIME_MS = 1000L
        private const val GPS_MIN_DISTANCE_M = 0f
        private const val NETWORK_MIN_TIME_MS = 5000L
        private const val NETWORK_MIN_DISTANCE_M = 10f
        private const val MAX_FLIGHT_FIXES = 20_000

        const val ACTION_START = "cl.heavenly.flightvis.ACTION_START_LOCAL_FLIGHT"
        const val ACTION_STOP = "cl.heavenly.flightvis.ACTION_STOP_LOCAL_FLIGHT"

        private val lock = Any()
        private val flightFixes = ArrayDeque<Map<String, Any?>>()
        private var lastTimeMs: Long? = null
        private var lastLat: Double? = null
        private var lastLon: Double? = null

        @Volatile
        var isRecording: Boolean = false
            private set

        fun hasLocationPermission(context: Context): Boolean {
            val fine =
                context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED
            val coarse =
                context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED
            return fine || coarse
        }

        private fun appendFlightFix(
            timeMs: Long,
            lat: Double,
            lon: Double,
            alt: Double?,
            bearing: Double?,
            speed: Double?,
        ) {
            synchronized(lock) {
                if (timeMs == lastTimeMs && lat == lastLat && lon == lastLon) return
                lastTimeMs = timeMs
                lastLat = lat
                lastLon = lon
                flightFixes.addLast(
                    mapOf(
                        "timeMs" to timeMs,
                        "lat" to lat,
                        "lon" to lon,
                        "alt" to alt,
                        "bearing" to bearing,
                        "speed" to speed,
                    ),
                )
                while (flightFixes.size > MAX_FLIGHT_FIXES) {
                    flightFixes.removeFirst()
                }
            }
        }

        fun snapshotFixes(): List<Map<String, Any?>> =
            synchronized(lock) {
                flightFixes.toList()
            }

        fun clearFixes() {
            synchronized(lock) {
                flightFixes.clear()
                lastTimeMs = null
                lastLat = null
                lastLon = null
            }
        }
    }
}
