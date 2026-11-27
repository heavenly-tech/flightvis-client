import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../storage/fix_upload_queue.dart';

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

  /// Persists the currently open broadcast [flightId] and [flightMode] on the
  /// native side so fixes captured while Dart is dead are tagged accurately.
  Future<void> setActiveFlight({
    required String flightId,
    String flightMode = 'club',
  }) async {
    final trimmed = flightId.trim();
    if (trimmed.isEmpty) {
      await clearActiveFlight();
      return;
    }
    try {
      await _channel.invokeMethod<void>('setActiveNativeFlight', {
        'flightId': trimmed,
        'flightMode': flightMode == 'personal' ? 'personal' : 'club',
      });
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
  Future<NativeQueueImportResult> importIntoStore(
    FixUploadQueueStore store,
  ) async {
    final fixes = await readQueuedFixes();
    if (fixes.isEmpty) return NativeQueueImportResult.empty;
    final added = await store.enqueueAll(fixes);
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
