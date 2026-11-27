package cl.heavenly.flightvis

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.traccar.client.sharedTracker

/**
 * In-memory ring buffer forwarding local GPS fixes to Flutter via
 * `EventChannel("cl.heavenly.flightvis/tracking_positions")`, plus native
 * on-disk fallback persistence ([NativeFixQueueStore]) when the Dart isolate is
 * detached or backgrounded during an offline/degraded broadcast flight.
 *
 * Used in two mutually exclusive modes:
 * - Club/personal broadcast: observes the Traccar SDK tracker's `StateFlow<State>`
 *   (`lastAcceptedLocation`) without opening a duplicate GPS subscription.
 * - Local-only recording: fed directly by [LocalFlightRecorderService] via
 *   [recordFix] with `persistToUploadQueue = false` (zero network/upload queue).
 */
object LocalPositionRecorder {
    private const val MAX_POINTS = 2000
    private const val MAX_AGE_MS = 120L * 60L * 1000L

    private val lock = Any()
    private val buffer = ArrayDeque<Map<String, Any?>>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var appForeground: Boolean = false

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var observerJob: Job? = null

    private var lastTimeMs: Long? = null
    private var lastLat: Double? = null
    private var lastLon: Double? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun setAppForeground(foreground: Boolean) {
        appForeground = foreground
    }

    fun setSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun recordFix(
        timeMs: Long,
        lat: Double,
        lon: Double,
        alt: Double?,
        bearing: Double?,
        speed: Double?,
        accuracy: Double? = null,
        persistToUploadQueue: Boolean = false,
    ) {
        if (!lat.isFinite() || !lon.isFinite()) return
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) return
        val safeAlt = alt?.takeIf { it.isFinite() }
        val safeBearing = bearing?.takeIf { it.isFinite() }
        val safeSpeed = speed?.takeIf { it.isFinite() }
        val safeAccuracy = accuracy?.takeIf { it.isFinite() }
        val payload =
            synchronized(lock) {
                if (timeMs == lastTimeMs && lat == lastLat && lon == lastLon) {
                    return@synchronized null
                }
                lastTimeMs = timeMs
                lastLat = lat
                lastLon = lon
                val entry =
                    mapOf<String, Any?>(
                        "timeMs" to timeMs,
                        "lat" to lat,
                        "lon" to lon,
                        "alt" to safeAlt,
                        "bearing" to safeBearing,
                        "speed" to safeSpeed,
                    )
                buffer.addLast(entry)
                val cutoff = timeMs - MAX_AGE_MS
                while (buffer.isNotEmpty()) {
                    val oldestTime = (buffer.first()["timeMs"] as? Number)?.toLong() ?: break
                    if (oldestTime < cutoff) {
                        buffer.removeFirst()
                    } else {
                        break
                    }
                }
                while (buffer.size > MAX_POINTS) {
                    buffer.removeFirst()
                }
                entry
            }
        if (payload != null) {
            if (persistToUploadQueue && !LocalFlightRecorderService.isRecording) {
                val ctx = appContext
                if (ctx != null) {
                    NativeFixQueueStore.appendForActiveFlight(
                        context = ctx,
                        timeMs = timeMs,
                        lat = lat,
                        lon = lon,
                        alt = safeAlt,
                        speed = safeSpeed,
                        course = safeBearing,
                        accuracy = safeAccuracy,
                    )
                }
            }
            val sink = eventSink
            if (sink != null) {
                mainHandler.post {
                    eventSink?.success(payload)
                }
            }
        }
    }

    fun startObserving() {
        synchronized(lock) {
            if (observerJob?.isActive == true) return
            observerJob =
                scope.launch {
                    var tracker = sharedTracker()
                    var attempts = 0
                    while (tracker == null && attempts < 20) {
                        delay(300)
                        tracker = sharedTracker()
                        attempts++
                    }
                    val activeTracker = tracker ?: return@launch
                    activeTracker.state.collect { state ->
                        val pos = state.lastAcceptedLocation ?: return@collect
                        val lat = pos.latitude ?: return@collect
                        val lon = pos.longitude ?: return@collect
                        val shouldPersist =
                            if (eventSink == null) {
                                true
                            } else if (!appForeground) {
                                val messages =
                                    try {
                                        activeTracker.getLogs().map { it.message }
                                    } catch (_: Exception) {
                                        emptyList()
                                    }
                                NativeFixQueueLogic.isLatestLogDegraded(messages)
                            } else {
                                false
                            }
                        recordFix(
                            timeMs = pos.time,
                            lat = lat,
                            lon = lon,
                            alt = pos.altitude,
                            bearing = pos.bearing?.toDouble(),
                            speed = pos.speed?.toDouble(),
                            persistToUploadQueue = shouldPersist,
                        )
                    }
                }
        }
    }

    fun snapshot(): List<Map<String, Any?>> =
        synchronized(lock) {
            buffer.toList()
        }

    fun clear() {
        synchronized(lock) {
            observerJob?.cancel()
            observerJob = null
            buffer.clear()
            lastTimeMs = null
            lastLat = null
            lastLon = null
        }
    }
}
