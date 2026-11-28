import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../storage/fix_upload_queue.dart';

/// Pure L-94 pre-start timestamp filter mirrored identically in Kotlin
/// `NativeFixQueueLogic.tagFixForActiveFlight`.
///
/// Enforces zero tolerance: any fix strictly older than [startedAtMs]
/// (`tMs < startedAtMs`) is dropped so Traccar's replayed last-known location
/// from before the flight started never enters the upload queue or own trail.
/// When [startedAtMs] is `null` or `<= 0`, all timestamps are accepted.
bool isFixAtOrAfterFlightStart({
  required int tMs,
  required int? startedAtMs,
}) {
  if (startedAtMs == null || startedAtMs <= 0) return true;
  return tMs >= startedAtMs;
}

/// Pure Dart mirror of Kotlin `NativeFixQueueLogic.tagFixForActiveFlight` so
/// unit tests verify active-flight tagging and the L-94 zero-tolerance
/// `tMs < startedAtMs` drop guard directly without a Kotlin JVM test harness.
QueuedFixInput? tagFixForActiveFlight({
  required String? activeFlightId,
  String? activeFlightMode,
  int? activeFlightStartedAtMs,
  required int tMs,
  required double lat,
  required double lon,
  double? alt,
  double? speed,
  double? course,
  double? accuracy,
}) {
  final trimmedFlightId = activeFlightId?.trim();
  if (trimmedFlightId == null || trimmedFlightId.isEmpty) return null;
  if (!isFixAtOrAfterFlightStart(tMs: tMs, startedAtMs: activeFlightStartedAtMs)) {
    return null;
  }
  double? finiteOrNull(double? v) => (v != null && v.isFinite) ? v : null;
  final input = QueuedFixInput(
    flightId: trimmedFlightId,
    flightMode: activeFlightMode?.trim() == 'personal' ? 'personal' : 'club',
    tMs: tMs,
    lat: lat,
    lon: lon,
    alt: finiteOrNull(alt),
    speed: finiteOrNull(speed),
    course: finiteOrNull(course),
    accuracy: finiteOrNull(accuracy),
  );
  return input.hasValidCoordinates ? input : null;
}

/// Result of importing natively persisted offline fixes into the Dart
/// [FixUploadQueueStore].
class NativeQueueImportResult {
  const NativeQueueImportResult({
    required this.readCount,
    required this.addedCount,
    required this.truncated,
  });

  static const empty = NativeQueueImportResult(
    readCount: 0,
    addedCount: 0,
    truncated: false,
  );

  final int readCount;
  final int addedCount;
  final bool truncated;
}

/// Dart boundary for the native Android on-disk fix queue
/// (`NativeFixQueueStore` in Kotlin via `cl.heavenly.flightvis/tracking`).
///
/// Guarantees:
/// - **H-8**: Persists active `(flightId, flightMode)` natively on tracking
///   start and clears it on stop so native fixes are tagged to their originating
///   flight and never silently retagged onto a later flight.
/// - **Atomic import & truncation**: Reads queued native fixes, merges them
///   into Dart's [FixUploadQueueStore] (deduplicated by `(flightId, tMs)`), and
///   truncates the native queue ONLY AFTER Dart persistence succeeds, passing
///   the imported dedup keys so concurrent native appends are preserved.
/// - **L-90**: Any debug logging is gated behind [enableDebugLogging] (default
///   `kDebugMode`) and never emits flight IDs or timestamps in release builds.
class NativeFixQueueBridge {
  const NativeFixQueueBridge({
    MethodChannel? channel,
    this.enableDebugLogging = kDebugMode,
    this.logger,
  }) : _channel = channel ?? defaultChannel;

  static const defaultChannel =
      MethodChannel('cl.heavenly.flightvis/tracking');

  final MethodChannel _channel;
  final bool enableDebugLogging;
  final void Function(String message)? logger;

  void _log(String msg) {
    if (!enableDebugLogging) return;
    final cb = logger;
    if (cb != null) {
      cb(msg);
    } else if (kDebugMode) {
      debugPrint('NativeFixQueueBridge: $msg');
    }
  }

  /// Persists the currently open broadcast [flightId], [flightMode], and
  /// optional [startedAtMs] (L-94) on the native side so fixes captured while
  /// Dart is dead are tagged accurately and pre-start points are dropped.
  Future<void> setActiveFlight({
    required String flightId,
    String flightMode = 'club',
    int? startedAtMs,
  }) async {
    final trimmed = flightId.trim();
    if (trimmed.isEmpty) {
      await clearActiveFlight();
      return;
    }
    try {
      final args = <String, Object>{
        'flightId': trimmed,
        'flightMode': flightMode == 'personal' ? 'personal' : 'club',
        if (startedAtMs != null && startedAtMs > 0) 'startedAtMs': startedAtMs,
      };
      await _channel.invokeMethod<void>('setActiveNativeFlight', args);
    } on MissingPluginException {
      // Non-Android platform or unit test without platform mock.
    } on PlatformException catch (e) {
      _log('setActiveNativeFlight failed: ${e.code}');
    }
  }

  /// Clears the natively persisted active flight so no further fixes are
  /// appended to the native queue after tracking stops.
  Future<void> clearActiveFlight() async {
    try {
      await _channel.invokeMethod<void>('clearActiveNativeFlight');
    } on MissingPluginException {
      // Non-Android / unit test.
    } on PlatformException catch (e) {
      _log('clearActiveNativeFlight failed: ${e.code}');
    }
  }

  /// Clears all entries from the native on-disk durable fix queue (L-93).
  Future<void> clearQueue() async {
    try {
      await _channel.invokeMethod<void>('clearNativeFixQueue');
    } on MissingPluginException {
      // Non-Android / unit test.
    } on PlatformException catch (e) {
      _log('clearNativeFixQueue failed: ${e.code}');
    }
  }

  /// Clears BOTH the native active flight metadata AND the native durable fix
  /// queue (L-93: called on logout, session expiry, and account change).
  Future<void> clearAll() async {
    await clearActiveFlight();
    await clearQueue();
  }

  /// Reads all valid queued fixes currently stored in the native JSONL file.
  Future<List<QueuedFixInput>> readQueuedFixes() async {
    try {
      final raw =
          await _channel.invokeListMethod<dynamic>('readNativeFixQueue');
      if (raw == null || raw.isEmpty) return const [];
      final parsed = <QueuedFixInput>[];
      for (final item in raw) {
        if (item is! Map<Object?, Object?>) continue;
        final fix = parseNativeFixMap(item);
        if (fix != null) parsed.add(fix);
      }
      return List<QueuedFixInput>.unmodifiable(parsed);
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      _log('readNativeFixQueue failed: ${e.code}');
      return const [];
    }
  }

  /// Atomically truncates imported entries from the native on-disk queue.
  Future<void> truncateQueuedFixes({Iterable<String>? importedDedupKeys}) async {
    try {
      final args = importedDedupKeys == null
          ? null
          : <String, dynamic>{'keys': importedDedupKeys.toList(growable: false)};
      await _channel.invokeMethod<void>('truncateNativeFixQueue', args);
    } on MissingPluginException {
      // Non-Android / unit test.
    } on PlatformException catch (e) {
      _log('truncateNativeFixQueue failed: ${e.code}');
    }
  }

  /// Imports all natively queued fixes into [store] (dedup by `(flightId, tMs)`,
  /// preserving each fix's original `flightId`) and atomically truncates the
  /// native file only after [store.enqueueAll] completes.
  ///
  /// When [activeFlightId] and [activeFlightStartedAtMs] are provided (L-94),
  /// any native-imported fix tagged with [activeFlightId] whose `tMs` is
  /// strictly earlier than [activeFlightStartedAtMs] is dropped before entering
  /// [store] while still truncating its key from the native file.
  Future<NativeQueueImportResult> importIntoStore(
    FixUploadQueueStore store, {
    String? activeFlightId,
    int? activeFlightStartedAtMs,
  }) async {
    final fixes = await readQueuedFixes();
    if (fixes.isEmpty) return NativeQueueImportResult.empty;
    final trimmedActive = activeFlightId?.trim();
    final eligible = (trimmedActive != null &&
            trimmedActive.isNotEmpty &&
            activeFlightStartedAtMs != null &&
            activeFlightStartedAtMs > 0)
        ? fixes
            .where(
              (f) =>
                  f.flightId != trimmedActive ||
                  isFixAtOrAfterFlightStart(
                    tMs: f.tMs,
                    startedAtMs: activeFlightStartedAtMs,
                  ),
            )
            .toList(growable: false)
        : fixes;
    final added =
        eligible.isEmpty ? 0 : await store.enqueueAll(eligible);
    await truncateQueuedFixes(
      importedDedupKeys: fixes.map((f) => f.dedupKey),
    );
    _log('Imported ${fixes.length} native fixes ($added new)');
    return NativeQueueImportResult(
      readCount: fixes.length,
      addedCount: added,
      truncated: true,
    );
  }

  /// Parses a single native map entry into a [QueuedFixInput], rejecting
  /// missing `flightId`, missing timestamp, or out-of-range coordinates.
  static QueuedFixInput? parseNativeFixMap(Map<Object?, Object?> raw) {
    final flightId = (raw['flightId'] as String?)?.trim();
    final timeRaw = raw['tMs'] ?? raw['t'];
    final latRaw = raw['lat'];
    final lonRaw = raw['lon'];
    if (flightId == null ||
        flightId.isEmpty ||
        timeRaw is! num ||
        latRaw is! num ||
        lonRaw is! num) {
      return null;
    }
    double? finiteOrNull(Object? value) {
      if (value is! num) return null;
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }

    final rawMode = (raw['flightMode'] as String?)?.trim();
    final input = QueuedFixInput(
      flightId: flightId,
      tMs: timeRaw.toInt(),
      lat: latRaw.toDouble(),
      lon: lonRaw.toDouble(),
      alt: finiteOrNull(raw['alt']),
      speed: finiteOrNull(raw['speed']),
      course: finiteOrNull(raw['course'] ?? raw['bearing']),
      accuracy: finiteOrNull(raw['accuracy']),
      flightMode: rawMode == 'personal' ? 'personal' : 'club',
    );
    return input.hasValidCoordinates ? input : null;
  }
}
