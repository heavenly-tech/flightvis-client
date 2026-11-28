package cl.heavenly.flightvis

import java.io.File
import java.io.FileOutputStream

/**
 * Single GPS fix persisted natively on disk while the Flutter Dart isolate is
 * dead or backgrounded in a degraded/offline state.
 *
 * Every fix is immutably tagged with the [flightId] and [flightMode] that were
 * active when the GPS fix was accepted (H-8: fixes from one flight can never
 * be silently retagged or uploaded onto a later flight).
 */
data class NativeQueuedFix(
    val flightId: String,
    val flightMode: String,
    val tMs: Long,
    val lat: Double,
    val lon: Double,
    val alt: Double? = null,
    val speed: Double? = null,
    val course: Double? = null,
    val accuracy: Double? = null,
) {
    val dedupKey: String
        get() = "$flightId|$tMs"

    fun toMap(): Map<String, Any?> =
        mapOf(
            "flightId" to flightId,
            "flightMode" to flightMode,
            "tMs" to tMs,
            "lat" to lat,
            "lon" to lon,
            "alt" to alt,
            "speed" to speed,
            "course" to course,
            "accuracy" to accuracy,
        )
}

/**
 * Pure Kotlin core logic for the native on-disk fix queue (zero Android
 * framework imports so every function is directly JVM unit-testable).
 */
object NativeFixQueueLogic {
    const val MAX_FIXES = 20_000

    private val uploadResponseRegex = Regex("^Upload response (\\d{3})$")

    fun normalizeMode(raw: String?): String =
        if (raw?.trim() == "personal") "personal" else "club"

    fun isValidCoordinate(lat: Double, lon: Double): Boolean =
        lat.isFinite() &&
            lon.isFinite() &&
            lat >= -90.0 &&
            lat <= 90.0 &&
            lon >= -180.0 &&
            lon <= 180.0

    /**
     * Tags a GPS fix with [activeFlightId] and [activeFlightMode].
     *
     * Returns `null` when no active flight is open, coordinates are invalid,
     * or [tMs] precedes [activeFlightStartedAtMs] (L-94: drop replayed
     * last-known fixes from before flight start with zero tolerance).
     */
    fun tagFixForActiveFlight(
        activeFlightId: String?,
        activeFlightMode: String?,
        tMs: Long,
        lat: Double,
        lon: Double,
        alt: Double? = null,
        speed: Double? = null,
        course: Double? = null,
        accuracy: Double? = null,
        activeFlightStartedAtMs: Long? = null,
    ): NativeQueuedFix? {
        val trimmedFlightId = activeFlightId?.trim()
        if (trimmedFlightId.isNullOrEmpty()) return null
        if (!isValidCoordinate(lat, lon)) return null
        if (activeFlightStartedAtMs != null && activeFlightStartedAtMs > 0L && tMs < activeFlightStartedAtMs) {
            return null
        }
        return NativeQueuedFix(
            flightId = trimmedFlightId,
            flightMode = normalizeMode(activeFlightMode),
            tMs = tMs,
            lat = lat,
            lon = lon,
            alt = alt?.takeIf { it.isFinite() },
            speed = speed?.takeIf { it.isFinite() },
            course = course?.takeIf { it.isFinite() },
            accuracy = accuracy?.takeIf { it.isFinite() },
        )
    }

    /**
     * H-8 pure filter: returns ONLY fixes whose `flightId` strictly equals
     * [activeFlightId] (returns empty when [activeFlightId] is null/blank).
     */
    fun filterForActiveFlight(
        fixes: List<NativeQueuedFix>,
        activeFlightId: String?,
    ): List<NativeQueuedFix> {
        val target = activeFlightId?.trim()
        if (target.isNullOrEmpty()) return emptyList()
        return fixes.filter { it.flightId == target }
    }

    /**
     * Deduplicates [fixes] by `(flightId, tMs)` (keeping first occurrence) and
     * caps the result to the newest [maxFixes] entries.
     */
    fun deduplicateAndCap(
        fixes: List<NativeQueuedFix>,
        maxFixes: Int = MAX_FIXES,
    ): List<NativeQueuedFix> {
        val safeCap = if (maxFixes < 0) 0 else maxFixes
        if (safeCap == 0 || fixes.isEmpty()) return emptyList()
        val seen = LinkedHashMap<String, NativeQueuedFix>(fixes.size)
        for (fix in fixes) {
            if (!seen.containsKey(fix.dedupKey)) {
                seen[fix.dedupKey] = fix
            }
        }
        val list = seen.values.toList()
        return if (list.size <= safeCap) list else list.subList(list.size - safeCap, list.size)
    }

    /**
     * Returns fixes that were NOT yet imported by Dart so concurrent native
     * appends arriving during an import are never dropped on atomic truncation.
     */
    fun removeImportedKeys(
        fixes: List<NativeQueuedFix>,
        importedDedupKeys: Set<String>?,
    ): List<NativeQueuedFix> {
        if (importedDedupKeys == null) return emptyList()
        if (importedDedupKeys.isEmpty()) return fixes
        return fixes.filter { it.dedupKey !in importedDedupKeys }
    }

    /**
     * Inspects Traccar SDK log messages (oldest -> newest) and returns `true`
     * when the most recent upload-status line indicates offline/429/5xx.
     */
    fun isLatestLogDegraded(messages: List<String>): Boolean {
        for (i in messages.indices.reversed()) {
            val trimmed = messages[i].trim()
            val match = uploadResponseRegex.matchEntire(trimmed)
            if (match != null) {
                val code = match.groupValues[1].toIntOrNull() ?: continue
                if (code in 200..299) return false
                if (code == 429 || code >= 500) return true
                if (code == 400 || code == 401 || code == 403) return false
            }
            val lower = trimmed.lowercase()
            if (lower.startsWith("upload error") ||
                lower.startsWith("upload failed") ||
                lower.startsWith("offline")
            ) {
                return true
            }
            if (lower.contains("network restored")) {
                return false
            }
        }
        return false
    }

    fun encodeJsonLine(fix: NativeQueuedFix): String {
        val sb = StringBuilder(160)
        sb.append("{\"flightId\":\"").append(escapeJsonString(fix.flightId))
        sb.append("\",\"flightMode\":\"").append(escapeJsonString(normalizeMode(fix.flightMode)))
        sb.append("\",\"t\":").append(fix.tMs)
        sb.append(",\"lat\":").append(fix.lat)
        sb.append(",\"lon\":").append(fix.lon)
        fix.alt?.takeIf { it.isFinite() }?.let { sb.append(",\"alt\":").append(it) }
        fix.speed?.takeIf { it.isFinite() }?.let { sb.append(",\"speed\":").append(it) }
        fix.course?.takeIf { it.isFinite() }?.let { sb.append(",\"course\":").append(it) }
        fix.accuracy?.takeIf { it.isFinite() }?.let { sb.append(",\"accuracy\":").append(it) }
        sb.append('}')
        return sb.toString()
    }

    fun decodeJsonLine(line: String): NativeQueuedFix? {
        val trimmed = line.trim()
        if (trimmed.length < 2 || trimmed[0] != '{' || trimmed[trimmed.length - 1] != '}') {
            return null
        }
        val fields = parseFlatJsonObject(trimmed) ?: return null
        val flightId = (fields["flightId"] as? String)?.trim()
        if (flightId.isNullOrEmpty()) return null
        val flightMode = normalizeMode(fields["flightMode"] as? String)
        val tMs = (fields["t"] as? String)?.toLongOrNull() ?: return null
        val lat = (fields["lat"] as? String)?.toDoubleOrNull() ?: return null
        val lon = (fields["lon"] as? String)?.toDoubleOrNull() ?: return null
        if (!isValidCoordinate(lat, lon)) return null
        val alt = (fields["alt"] as? String)?.toDoubleOrNull()?.takeIf { it.isFinite() }
        val speed = (fields["speed"] as? String)?.toDoubleOrNull()?.takeIf { it.isFinite() }
        val course = (fields["course"] as? String)?.toDoubleOrNull()?.takeIf { it.isFinite() }
        val accuracy = (fields["accuracy"] as? String)?.toDoubleOrNull()?.takeIf { it.isFinite() }
        return NativeQueuedFix(
            flightId = flightId,
            flightMode = flightMode,
            tMs = tMs,
            lat = lat,
            lon = lon,
            alt = alt,
            speed = speed,
            course = course,
            accuracy = accuracy,
        )
    }

    private fun escapeJsonString(raw: String): String {
        val sb = StringBuilder(raw.length)
        for (ch in raw) {
            when (ch) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> {
                    if (ch.code < 0x20) {
                        sb.append("\\u").append(ch.code.toString(16).padStart(4, '0'))
                    } else {
                        sb.append(ch)
                    }
                }
            }
        }
        return sb.toString()
    }

    private fun parseFlatJsonObject(json: String): Map<String, Any?>? {
        val out = HashMap<String, Any?>()
        var idx = 1
        val end = json.length - 1

        fun skipWhitespace() {
            while (idx < end && json[idx].isWhitespace()) idx++
        }

        fun readQuotedString(): String? {
            if (idx >= end || json[idx] != '"') return null
            idx++
            val sb = StringBuilder()
            while (idx < end) {
                val ch = json[idx++]
                if (ch == '"') return sb.toString()
                if (ch == '\\') {
                    if (idx >= end) return null
                    when (val esc = json[idx++]) {
                        '"', '\\', '/' -> sb.append(esc)
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'u' -> {
                            if (idx + 4 > end) return null
                            val hex = json.substring(idx, idx + 4)
                            val code = hex.toIntOrNull(16) ?: return null
                            sb.append(code.toChar())
                            idx += 4
                        }
                        else -> return null
                    }
                } else {
                    sb.append(ch)
                }
            }
            return null
        }

        skipWhitespace()
        while (idx < end) {
            val key = readQuotedString() ?: return null
            skipWhitespace()
            if (idx >= end || json[idx] != ':') return null
            idx++
            skipWhitespace()
            if (idx >= end) return null
            val value: Any? =
                if (json[idx] == '"') {
                    readQuotedString() ?: return null
                } else {
                    val start = idx
                    while (idx < end && json[idx] != ',' && !json[idx].isWhitespace()) {
                        idx++
                    }
                    val token = json.substring(start, idx)
                    if (token == "null") null else token
                }
            out[key] = value
            skipWhitespace()
            if (idx < end) {
                if (json[idx] != ',') return null
                idx++
                skipWhitespace()
            }
        }
        return out
    }
}

/**
 * Bounded, atomic JSONL file queue storing [NativeQueuedFix] entries on disk.
 *
 * Uses only `java.io.File` (no Android dependencies) and caps persisted size
 * to [maxFixes] (default 20,000) via atomic `.tmp` + rename compaction.
 */
class NativeFixQueueFile(
    private val file: File,
    private val maxFixes: Int = NativeFixQueueLogic.MAX_FIXES,
) {
    private val lock = Any()
    private var approxLines: Int = -1

    fun append(fix: NativeQueuedFix): Boolean {
        if (fix.flightId.isBlank() || !NativeFixQueueLogic.isValidCoordinate(fix.lat, fix.lon)) {
            return false
        }
        synchronized(lock) {
            file.parentFile?.let { parent ->
                if (!parent.exists()) parent.mkdirs()
            }
            if (approxLines < 0) {
                approxLines = if (file.exists()) file.useLines { it.count() } else 0
            }
            val lineBytes = (NativeFixQueueLogic.encodeJsonLine(fix) + "\n").toByteArray(Charsets.UTF_8)
            FileOutputStream(file, true).use { fos ->
                fos.write(lineBytes)
                fos.flush()
            }
            approxLines++
            val compactThreshold = if (maxFixes < 1000) maxFixes else maxFixes + 1000
            if (approxLines > compactThreshold) {
                compactUnlocked()
            }
            return true
        }
    }

    fun readAll(): List<NativeQueuedFix> =
        synchronized(lock) {
            readAllUnlocked()
        }

    /**
     * Atomically truncates imported entries from disk.
     *
     * When [importedDedupKeys] is `null`, removes the entire queue file.
     * Otherwise rewrites only fixes NOT in [importedDedupKeys] to `.tmp` and
     * atomically renames into place (or deletes the file when none remain).
     */
    fun truncateImported(importedDedupKeys: Set<String>?) {
        synchronized(lock) {
            if (!file.exists()) {
                approxLines = 0
                return
            }
            if (importedDedupKeys == null) {
                file.delete()
                tempFile().delete()
                approxLines = 0
                return
            }
            val all = readAllUnlocked()
            val remaining = NativeFixQueueLogic.removeImportedKeys(all, importedDedupKeys)
            if (remaining.isEmpty()) {
                file.delete()
                tempFile().delete()
                approxLines = 0
                return
            }
            writeAtomicUnlocked(remaining)
        }
    }

    private fun tempFile(): File = File(file.parentFile, "${file.name}.tmp")

    private fun readAllUnlocked(): List<NativeQueuedFix> {
        if (!file.exists()) return emptyList()
        val parsed = ArrayList<NativeQueuedFix>()
        file.useLines(Charsets.UTF_8) { lines ->
            for (line in lines) {
                val fix = NativeFixQueueLogic.decodeJsonLine(line)
                if (fix != null) parsed.add(fix)
            }
        }
        return NativeFixQueueLogic.deduplicateAndCap(parsed, maxFixes)
    }

    private fun compactUnlocked() {
        val kept = readAllUnlocked()
        if (kept.isEmpty()) {
            file.delete()
            tempFile().delete()
            approxLines = 0
        } else {
            writeAtomicUnlocked(kept)
        }
    }

    private fun writeAtomicUnlocked(fixes: List<NativeQueuedFix>) {
        file.parentFile?.let { parent ->
            if (!parent.exists()) parent.mkdirs()
        }
        val tmp = tempFile()
        FileOutputStream(tmp, false).use { fos ->
            for (fix in fixes) {
                fos.write((NativeFixQueueLogic.encodeJsonLine(fix) + "\n").toByteArray(Charsets.UTF_8))
            }
            fos.flush()
            try {
                fos.fd.sync()
            } catch (_: Exception) {
            }
        }
        if (!tmp.renameTo(file)) {
            file.delete()
            if (!tmp.renameTo(file)) {
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
        }
        approxLines = fixes.size
    }
}
