package cl.heavenly.flightvis

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Android persistence wrapper for [NativeFixQueueFile] and the active flight
 * tag in private `SharedPreferences`.
 *
 * Security & privacy guarantees:
 * - **H-8**: Persists the currently open broadcast `flightId` and `flightMode`
 *   when tracking starts and clears them on stop / check-in expiry. Never
 *   appends untagged fixes, and never retags stored fixes.
 * - **L-90**: Never logs flight IDs, coordinates, or timestamps.
 */
object NativeFixQueueStore {
    private const val TAG = "NativeFixQueueStore"
    private const val PREFS_NAME = "flightvis_native_fix_queue"
    private const val KEY_ACTIVE_FLIGHT_ID = "active_flight_id"
    private const val KEY_ACTIVE_FLIGHT_MODE = "active_flight_mode"
    private const val KEY_ACTIVE_FLIGHT_STARTED_AT_MS = "active_flight_started_at_ms"
    private const val QUEUE_DIR = "native_fix_queue"
    private const val QUEUE_FILE = "queue.jsonl"

    private val instanceLock = Any()

    @Volatile
    private var queueFileInstance: NativeFixQueueFile? = null

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun queueFile(context: Context): NativeFixQueueFile {
        val existing = queueFileInstance
        if (existing != null) return existing
        synchronized(instanceLock) {
            val again = queueFileInstance
            if (again != null) return again
            val dir = File(context.applicationContext.filesDir, QUEUE_DIR)
            val created = NativeFixQueueFile(File(dir, QUEUE_FILE), NativeFixQueueLogic.MAX_FIXES)
            queueFileInstance = created
            return created
        }
    }

    fun setActiveFlight(
        context: Context,
        flightId: String,
        flightMode: String,
        startedAtMs: Long? = null,
    ) {
        val trimmedId = flightId.trim()
        if (trimmedId.isEmpty()) {
            clearActiveFlight(context)
            return
        }
        val mode = NativeFixQueueLogic.normalizeMode(flightMode)
        try {
            val editor =
                prefs(context)
                    .edit()
                    .putString(KEY_ACTIVE_FLIGHT_ID, trimmedId)
                    .putString(KEY_ACTIVE_FLIGHT_MODE, mode)
            if (startedAtMs != null && startedAtMs > 0L) {
                editor.putLong(KEY_ACTIVE_FLIGHT_STARTED_AT_MS, startedAtMs)
            } else {
                editor.remove(KEY_ACTIVE_FLIGHT_STARTED_AT_MS)
            }
            editor.commit()
        } catch (_: Exception) {
            Log.w(TAG, "Failed to persist active flight metadata")
        }
    }

    fun clearActiveFlight(context: Context) {
        try {
            prefs(context)
                .edit()
                .remove(KEY_ACTIVE_FLIGHT_ID)
                .remove(KEY_ACTIVE_FLIGHT_MODE)
                .remove(KEY_ACTIVE_FLIGHT_STARTED_AT_MS)
                .commit()
        } catch (_: Exception) {
            Log.w(TAG, "Failed to clear active flight metadata")
        }
    }

    fun clearQueue(context: Context) {
        truncateImported(context, null)
    }

    fun activeFlightId(context: Context): String? =
        try {
            prefs(context).getString(KEY_ACTIVE_FLIGHT_ID, null)?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }

    fun activeFlightMode(context: Context): String =
        try {
            NativeFixQueueLogic.normalizeMode(prefs(context).getString(KEY_ACTIVE_FLIGHT_MODE, null))
        } catch (_: Exception) {
            "club"
        }

    fun activeFlightStartedAtMs(context: Context): Long? =
        try {
            val stored = prefs(context).getLong(KEY_ACTIVE_FLIGHT_STARTED_AT_MS, -1L)
            if (stored > 0L) stored else null
        } catch (_: Exception) {
            null
        }

    fun appendForActiveFlight(
        context: Context,
        timeMs: Long,
        lat: Double,
        lon: Double,
        alt: Double?,
        speed: Double?,
        course: Double?,
        accuracy: Double? = null,
    ): Boolean {
        val flightId = activeFlightId(context) ?: return false
        val flightMode = activeFlightMode(context)
        val startedAtMs = activeFlightStartedAtMs(context)
        val tagged =
            NativeFixQueueLogic.tagFixForActiveFlight(
                activeFlightId = flightId,
                activeFlightMode = flightMode,
                tMs = timeMs,
                lat = lat,
                lon = lon,
                alt = alt,
                speed = speed,
                course = course,
                accuracy = accuracy,
                activeFlightStartedAtMs = startedAtMs,
            ) ?: return false
        return try {
            queueFile(context).append(tagged)
        } catch (_: Exception) {
            Log.w(TAG, "Failed to append fix to native queue")
            false
        }
    }

    fun readAllAsMaps(context: Context): List<Map<String, Any?>> =
        try {
            queueFile(context).readAll().map { it.toMap() }
        } catch (_: Exception) {
            Log.w(TAG, "Failed to read native fix queue")
            emptyList()
        }

    fun truncateImported(
        context: Context,
        importedDedupKeys: Set<String>?,
    ) {
        try {
            queueFile(context).truncateImported(importedDedupKeys)
        } catch (_: Exception) {
            Log.w(TAG, "Failed to truncate native fix queue")
        }
    }
}
