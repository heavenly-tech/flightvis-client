import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../map/own_trail_buffer.dart';
import 'local_flight_store.dart';

/// Input payload for enqueuing a GPS fix into the store-and-forward upload queue.
class QueuedFixInput {
  const QueuedFixInput({
    required this.flightId,
    required this.tMs,
    required this.lat,
    required this.lon,
    this.alt,
    this.speed,
    this.course,
    this.accuracy,
    this.flightMode = 'club',
  });

  factory QueuedFixInput.fromLocalFix(
    LocalFix fix, {
    required String flightId,
    String flightMode = 'club',
  }) =>
      QueuedFixInput(
        flightId: flightId,
        tMs: fix.timeMs,
        lat: fix.latitude,
        lon: fix.longitude,
        alt: fix.altitude,
        speed: fix.speed,
        course: fix.bearing,
        flightMode: flightMode,
      );

  final String flightId;
  final int tMs;
  final double lat;
  final double lon;
  final double? alt;
  final double? speed;
  final double? course;
  final double? accuracy;

  /// `'club'` or `'personal'` — selects which device bearer token from
  /// `SecureStore` is used on upload (never persists raw bearer tokens on disk).
  final String flightMode;

  bool get hasValidCoordinates =>
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90.0 &&
      lat <= 90.0 &&
      lon >= -180.0 &&
      lon <= 180.0;

  String get dedupKey => QueuedFix.makeDedupKey(flightId, tMs);
}

/// Persisted fix awaiting batch upload to `POST /api/ingest`, or retained
/// local-only under its original [flightId] for future completed-flight upload
/// (E2) once that flight is no longer open (H-8).
///
/// Keyed by `(flightId, tMs)` so retries, timeouts, and re-enqueues never
/// create client-side duplicates; carries a monotonic client `seq` and
/// `flightId` alongside device timestamp `tMs`.
class QueuedFix {
  const QueuedFix({
    required this.flightId,
    required this.seq,
    required this.tMs,
    required this.lat,
    required this.lon,
    this.alt,
    this.speed,
    this.course,
    this.accuracy,
    this.flightMode = 'club',
    int? enqueuedAtMs,
  }) : enqueuedAtMs = enqueuedAtMs ?? tMs;

  final String flightId;
  final int seq;
  final int tMs;
  final double lat;
  final double lon;
  final double? alt;
  final double? speed;
  final double? course;
  final double? accuracy;
  final String flightMode;

  /// Local wall-clock timestamp when this fix entered the store (used for
  /// bounded 7-day orphaned-flight retention; never sent over the wire).
  final int enqueuedAtMs;

  static String makeDedupKey(String flightId, int tMs) => '$flightId|$tMs';

  String get dedupKey => makeDedupKey(flightId, tMs);

  /// Serializes this fix into the `IngestFixInput` JSON object expected by
  /// `POST /api/ingest` (`server-rs/src/live/types.rs:48-61`).
  ///
  /// Server `IngestFixInput` does NOT set `#[serde(deny_unknown_fields)]`, so
  /// order metadata (`seq`, `flight_id`) is safely ignored by E1 and preserved
  /// for late-fix ordering.
  Map<String, dynamic> toIngestJson() => {
        't': tMs,
        'lat': lat,
        'lon': lon,
        if (alt != null && alt!.isFinite) 'alt': alt,
        if (speed != null && speed!.isFinite) 'speed': speed,
        if (course != null && course!.isFinite) 'course': course,
        if (accuracy != null && accuracy!.isFinite) 'accuracy': accuracy,
        'seq': seq,
        'flight_id': flightId,
      };

  Map<String, dynamic> toStorageJson() => {
        'flightId': flightId,
        'seq': seq,
        't': tMs,
        'lat': lat,
        'lon': lon,
        if (alt != null && alt!.isFinite) 'alt': alt,
        if (speed != null && speed!.isFinite) 'speed': speed,
        if (course != null && course!.isFinite) 'course': course,
        if (accuracy != null && accuracy!.isFinite) 'accuracy': accuracy,
        'flightMode': flightMode,
        'enqueuedAtMs': enqueuedAtMs,
      };

  static QueuedFix? fromStorageJson(Map<String, dynamic> json) {
    final flightId = (json['flightId'] as String?)?.trim();
    final seq = (json['seq'] as num?)?.toInt();
    final t = (json['t'] as num?)?.toInt();
    final lat = (json['lat'] as num?)?.toDouble();
    final lon = (json['lon'] as num?)?.toDouble();
    if (flightId == null ||
        flightId.isEmpty ||
        seq == null ||
        t == null ||
        lat == null ||
        lon == null) {
      return null;
    }
    if (!lat.isFinite ||
        !lon.isFinite ||
        lat < -90.0 ||
        lat > 90.0 ||
        lon < -180.0 ||
        lon > 180.0) {
      return null;
    }
    double? finiteOrNull(dynamic raw) {
      if (raw is! num) return null;
      final v = raw.toDouble();
      return v.isFinite ? v : null;
    }

    final rawMode = (json['flightMode'] as String?)?.trim();
    final enqueuedAtMs = (json['enqueuedAtMs'] as num?)?.toInt() ?? t;
    return QueuedFix(
      flightId: flightId,
      seq: seq,
      tMs: t,
      lat: lat,
      lon: lon,
      alt: finiteOrNull(json['alt']),
      speed: finiteOrNull(json['speed']),
      course: finiteOrNull(json['course']),
      accuracy: finiteOrNull(json['accuracy']),
      flightMode: rawMode == 'personal' ? 'personal' : 'club',
      enqueuedAtMs: enqueuedAtMs,
    );
  }
}

/// Persistent store-and-forward queue for broadcast fixes awaiting batch upload.
///
/// H-8 flight scoping & bounded orphaned retention:
/// - Live uploads ONLY peek batches matching the currently open [flightId]
///   via [peekOldestBatch].
/// - Leftover fixes from ended/other flights stay persisted locally tagged
///   with their original [flightId] (never silently retagged and never posted
///   to a later open flight), awaiting future completed-flight upload (E2).
/// - [pruneOrphaned] bounds local-only retention to at most
///   [orphanedRetentionMaxAge] (7 days) and at most [maxOrphanedFlights] (20)
///   distinct non-active flights.
abstract class FixUploadQueueStore {
  static const int maxBatchSize = 100;
  static const int maxQueuedFixes = 50000;
  static const Duration orphanedRetentionMaxAge = Duration(days: 7);
  static const int maxOrphanedFlights = 20;

  /// Adds [fix] if its `(flightId, tMs)` key is not already present.
  /// Returns `true` when newly enqueued, `false` when deduplicated or invalid.
  Future<bool> enqueue(QueuedFixInput fix);

  /// Adds all valid, non-duplicate fixes in [fixes]. Returns number added.
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes);

  /// Returns pending fixes ordered oldest-first (`tMs` asc, `seq` asc).
  /// When [flightId] is provided, returns only fixes tagged with [flightId].
  Future<List<QueuedFix>> listAll({String? flightId});

  /// Returns local-only leftover fixes grouped by `flightId`, excluding
  /// [activeFlightId] if provided (for future E2 completed-flight upload).
  Future<Map<String, List<QueuedFix>>> listOrphanedByFlight({
    String? activeFlightId,
  });

  /// Returns the number of queued fixes (scoped to [flightId] when non-null).
  Future<int> count({String? flightId});

  /// Peeks up to [maxCount] (clamped to `1..maxBatchSize`) oldest fixes whose
  /// `flightId` strictly equals [flightId] (H-8: never returns fixes belonging
  /// to any other flight).
  Future<List<QueuedFix>> peekOldestBatch({
    required String flightId,
    int maxCount = maxBatchSize,
  });

  /// Removes ONLY entries whose `dedupKey` is in [dedupKeys] (called after a
  /// 2xx response covering those fixes, or when dropping a single unsplitable
  /// oversized fix).
  Future<int> removeKeys(Iterable<String> dedupKeys);

  /// Enforces bounded retention on local-only orphaned flights (any flight
  /// other than [activeFlightId]): removes orphaned flights older than
  /// [maxAge] (default 7 days) or beyond the newest [maxFlights] (default 20)
  /// orphaned flights. Never removes fixes tagged with [activeFlightId].
  /// Returns the number of fixes pruned.
  Future<int> pruneOrphaned({
    String? activeFlightId,
    DateTime? now,
    Duration maxAge = orphanedRetentionMaxAge,
    int maxFlights = maxOrphanedFlights,
  });

  /// Clears all queued entries for [flightId] (or all entries if null).
  Future<void> clear({String? flightId});
}

int _compareQueuedFix(QueuedFix a, QueuedFix b) {
  final byTime = a.tMs.compareTo(b.tMs);
  if (byTime != 0) return byTime;
  final bySeq = a.seq.compareTo(b.seq);
  if (bySeq != 0) return bySeq;
  return a.flightId.compareTo(b.flightId);
}

int _pruneOrphanedUnlocked(
  Map<String, QueuedFix> byKey, {
  required String? activeFlightId,
  required int nowMs,
  required Duration maxAge,
  required int maxFlights,
}) {
  final active = activeFlightId?.trim();
  final groups = <String, List<QueuedFix>>{};
  for (final fix in byKey.values) {
    if (active != null && active.isNotEmpty && fix.flightId == active) {
      continue;
    }
    groups.putIfAbsent(fix.flightId, () => <QueuedFix>[]).add(fix);
  }
  if (groups.isEmpty) return 0;

  final cutoffMs = nowMs - maxAge.inMilliseconds;
  final surviving = <MapEntry<String, int>>[];
  final toRemove = <String>[];

  for (final entry in groups.entries) {
    var newestActivityMs = entry.value.first.enqueuedAtMs;
    for (final fix in entry.value.skip(1)) {
      if (fix.enqueuedAtMs > newestActivityMs) {
        newestActivityMs = fix.enqueuedAtMs;
      }
    }
    if (newestActivityMs < cutoffMs) {
      for (final fix in entry.value) {
        toRemove.add(fix.dedupKey);
      }
    } else {
      surviving.add(MapEntry(entry.key, newestActivityMs));
    }
  }

  final safeMaxFlights = maxFlights < 0 ? 0 : maxFlights;
  if (surviving.length > safeMaxFlights) {
    surviving.sort((a, b) {
      final byRecent = b.value.compareTo(a.value);
      if (byRecent != 0) return byRecent;
      return b.key.compareTo(a.key);
    });
    for (var i = safeMaxFlights; i < surviving.length; i++) {
      final flightId = surviving[i].key;
      for (final fix in groups[flightId]!) {
        toRemove.add(fix.dedupKey);
      }
    }
  }

  var removed = 0;
  for (final k in toRemove) {
    if (byKey.remove(k) != null) removed++;
  }
  return removed;
}

Map<String, List<QueuedFix>> _orphanedByFlightUnlocked(
  Map<String, QueuedFix> byKey, {
  required String? activeFlightId,
}) {
  final active = activeFlightId?.trim();
  final grouped = <String, List<QueuedFix>>{};
  for (final fix in byKey.values) {
    if (active != null && active.isNotEmpty && fix.flightId == active) {
      continue;
    }
    grouped.putIfAbsent(fix.flightId, () => <QueuedFix>[]).add(fix);
  }
  for (final list in grouped.values) {
    list.sort(_compareQueuedFix);
  }
  return Map<String, List<QueuedFix>>.unmodifiable({
    for (final e in grouped.entries)
      e.key: List<QueuedFix>.unmodifiable(e.value),
  });
}

List<QueuedFix> _peekBatchUnlocked(
  Map<String, QueuedFix> byKey, {
  required String flightId,
  required int maxCount,
}) {
  final target = flightId.trim();
  if (target.isEmpty || byKey.isEmpty) return const [];
  final cap = maxCount.clamp(1, FixUploadQueueStore.maxBatchSize);
  final matching = byKey.values
      .where((f) => f.flightId == target)
      .toList()
    ..sort(_compareQueuedFix);
  if (matching.isEmpty) return const [];
  final headMode = matching.first.flightMode;
  final batch = <QueuedFix>[];
  for (final fix in matching) {
    if (fix.flightMode != headMode) continue;
    batch.add(fix);
    if (batch.length >= cap) break;
  }
  return List<QueuedFix>.unmodifiable(batch);
}

/// Disk-backed [FixUploadQueueStore] persisting atomically to
/// `<appDocumentsDir>/upload_queue/<accountBucket>/queue.json`.
class FileFixUploadQueueStore implements FixUploadQueueStore {
  FileFixUploadQueueStore({
    Future<Directory> Function()? directoryProvider,
    String accountBucket = LocalFlightStore.guestBucket,
    int maxFixes = FixUploadQueueStore.maxQueuedFixes,
    DateTime Function()? clock,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _accountBucket = LocalFlightStore.sanitizeBucket(accountBucket),
        _maxFixes = maxFixes,
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _directoryProvider;
  final String _accountBucket;
  final int _maxFixes;
  final DateTime Function() _clock;

  bool _loaded = false;
  int _nextSeq = 1;
  final Map<String, QueuedFix> _byKey = {};
  Future<void> _opChain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _opChain.then((_) => action());
    _opChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<File> _queueFile() async {
    final base = await _directoryProvider();
    final sep = Platform.pathSeparator;
    final dir = Directory('${base.path}${sep}upload_queue$sep$_accountBucket');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${sep}queue.json');
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _queueFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final storedNextSeq = (decoded['nextSeq'] as num?)?.toInt();
      if (storedNextSeq != null && storedNextSeq > _nextSeq) {
        _nextSeq = storedNextSeq;
      }
      final rawItems = decoded['items'] as List<dynamic>? ?? const [];
      for (final entry in rawItems) {
        if (entry is! Map<String, dynamic>) continue;
        final fix = QueuedFix.fromStorageJson(entry);
        if (fix == null) continue;
        _byKey.putIfAbsent(fix.dedupKey, () => fix);
        if (fix.seq >= _nextSeq) {
          _nextSeq = fix.seq + 1;
        }
      }
    } catch (_) {
      // Ignore corrupt queue file cleanly so tracking never crashes.
    }
  }

  Future<void> _persist() async {
    final file = await _queueFile();
    final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
    final payload = {
      'version': 2,
      'nextSeq': _nextSeq,
      'items': [for (final f in ordered) f.toStorageJson()],
    };
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(file.path);
  }

  void _enforceCap() {
    if (_byKey.length <= _maxFixes) return;
    final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
    final dropCount = ordered.length - _maxFixes;
    for (var i = 0; i < dropCount; i++) {
      _byKey.remove(ordered[i].dedupKey);
    }
  }

  bool _insertUnlocked(QueuedFixInput input, int enqueuedAtMs) {
    final flightId = input.flightId.trim();
    if (flightId.isEmpty || !input.hasValidCoordinates) return false;
    final key = QueuedFix.makeDedupKey(flightId, input.tMs);
    if (_byKey.containsKey(key)) return false;
    _byKey[key] = QueuedFix(
      flightId: flightId,
      seq: _nextSeq++,
      tMs: input.tMs,
      lat: input.lat,
      lon: input.lon,
      alt: input.alt,
      speed: input.speed,
      course: input.course,
      accuracy: input.accuracy,
      flightMode: input.flightMode == 'personal' ? 'personal' : 'club',
      enqueuedAtMs: enqueuedAtMs,
    );
    return true;
  }

  @override
  Future<bool> enqueue(QueuedFixInput fix) => _serialized(() async {
        await _ensureLoaded();
        final added = _insertUnlocked(fix, _clock().millisecondsSinceEpoch);
        if (added) {
          _enforceCap();
          await _persist();
        }
        return added;
      });

  @override
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes) =>
      _serialized(() async {
        await _ensureLoaded();
        final nowMs = _clock().millisecondsSinceEpoch;
        var added = 0;
        for (final fix in fixes) {
          if (_insertUnlocked(fix, nowMs)) added++;
        }
        if (added > 0) {
          _enforceCap();
          await _persist();
        }
        return added;
      });

  @override
  Future<List<QueuedFix>> listAll({String? flightId}) => _serialized(() async {
        await _ensureLoaded();
        final filter = flightId?.trim();
        final items = (filter == null || filter.isEmpty)
            ? _byKey.values.toList()
            : _byKey.values.where((f) => f.flightId == filter).toList();
        items.sort(_compareQueuedFix);
        return List<QueuedFix>.unmodifiable(items);
      });

  @override
  Future<Map<String, List<QueuedFix>>> listOrphanedByFlight({
    String? activeFlightId,
  }) =>
      _serialized(() async {
        await _ensureLoaded();
        return _orphanedByFlightUnlocked(
          _byKey,
          activeFlightId: activeFlightId,
        );
      });

  @override
  Future<int> count({String? flightId}) => _serialized(() async {
        await _ensureLoaded();
        final filter = flightId?.trim();
        if (filter == null || filter.isEmpty) return _byKey.length;
        var total = 0;
        for (final f in _byKey.values) {
          if (f.flightId == filter) total++;
        }
        return total;
      });

  @override
  Future<List<QueuedFix>> peekOldestBatch({
    required String flightId,
    int maxCount = FixUploadQueueStore.maxBatchSize,
  }) =>
      _serialized(() async {
        await _ensureLoaded();
        return _peekBatchUnlocked(
          _byKey,
          flightId: flightId,
          maxCount: maxCount,
        );
      });

  @override
  Future<int> removeKeys(Iterable<String> dedupKeys) => _serialized(() async {
        await _ensureLoaded();
        var removed = 0;
        for (final k in dedupKeys) {
          if (_byKey.remove(k) != null) removed++;
        }
        if (removed > 0) {
          await _persist();
        }
        return removed;
      });

  @override
  Future<int> pruneOrphaned({
    String? activeFlightId,
    DateTime? now,
    Duration maxAge = FixUploadQueueStore.orphanedRetentionMaxAge,
    int maxFlights = FixUploadQueueStore.maxOrphanedFlights,
  }) =>
      _serialized(() async {
        await _ensureLoaded();
        final removed = _pruneOrphanedUnlocked(
          _byKey,
          activeFlightId: activeFlightId,
          nowMs: (now ?? _clock()).millisecondsSinceEpoch,
          maxAge: maxAge,
          maxFlights: maxFlights,
        );
        if (removed > 0) {
          await _persist();
        }
        return removed;
      });

  @override
  Future<void> clear({String? flightId}) => _serialized(() async {
        await _ensureLoaded();
        if (flightId == null) {
          if (_byKey.isEmpty) return;
          _byKey.clear();
          await _persist();
          return;
        }
        final before = _byKey.length;
        _byKey.removeWhere((_, v) => v.flightId == flightId);
        if (_byKey.length != before) {
          await _persist();
        }
      });
}

/// Deterministic in-memory [FixUploadQueueStore] for unit/widget tests.
class InMemoryFixUploadQueueStore implements FixUploadQueueStore {
  InMemoryFixUploadQueueStore({
    int maxFixes = FixUploadQueueStore.maxQueuedFixes,
    DateTime Function()? clock,
  })  : _maxFixes = maxFixes,
        _clock = clock ?? DateTime.now;

  final int _maxFixes;
  final DateTime Function() _clock;
  int _nextSeq = 1;
  final Map<String, QueuedFix> _byKey = {};

  void _enforceCap() {
    if (_byKey.length <= _maxFixes) return;
    final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
    final dropCount = ordered.length - _maxFixes;
    for (var i = 0; i < dropCount; i++) {
      _byKey.remove(ordered[i].dedupKey);
    }
  }

  bool _insert(QueuedFixInput input, int enqueuedAtMs) {
    final flightId = input.flightId.trim();
    if (flightId.isEmpty || !input.hasValidCoordinates) return false;
    final key = QueuedFix.makeDedupKey(flightId, input.tMs);
    if (_byKey.containsKey(key)) return false;
    _byKey[key] = QueuedFix(
      flightId: flightId,
      seq: _nextSeq++,
      tMs: input.tMs,
      lat: input.lat,
      lon: input.lon,
      alt: input.alt,
      speed: input.speed,
      course: input.course,
      accuracy: input.accuracy,
      flightMode: input.flightMode == 'personal' ? 'personal' : 'club',
      enqueuedAtMs: enqueuedAtMs,
    );
    return true;
  }

  @override
  Future<bool> enqueue(QueuedFixInput fix) async {
    final added = _insert(fix, _clock().millisecondsSinceEpoch);
    if (added) _enforceCap();
    return added;
  }

  @override
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes) async {
    final nowMs = _clock().millisecondsSinceEpoch;
    var added = 0;
    for (final f in fixes) {
      if (_insert(f, nowMs)) added++;
    }
    if (added > 0) _enforceCap();
    return added;
  }

  @override
  Future<List<QueuedFix>> listAll({String? flightId}) async {
    final filter = flightId?.trim();
    final ordered = (filter == null || filter.isEmpty)
        ? _byKey.values.toList()
        : _byKey.values.where((f) => f.flightId == filter).toList();
    ordered.sort(_compareQueuedFix);
    return List<QueuedFix>.unmodifiable(ordered);
  }

  @override
  Future<Map<String, List<QueuedFix>>> listOrphanedByFlight({
    String? activeFlightId,
  }) async =>
      _orphanedByFlightUnlocked(_byKey, activeFlightId: activeFlightId);

  @override
  Future<int> count({String? flightId}) async {
    final filter = flightId?.trim();
    if (filter == null || filter.isEmpty) return _byKey.length;
    var total = 0;
    for (final f in _byKey.values) {
      if (f.flightId == filter) total++;
    }
    return total;
  }

  @override
  Future<List<QueuedFix>> peekOldestBatch({
    required String flightId,
    int maxCount = FixUploadQueueStore.maxBatchSize,
  }) async =>
      _peekBatchUnlocked(_byKey, flightId: flightId, maxCount: maxCount);

  @override
  Future<int> removeKeys(Iterable<String> dedupKeys) async {
    var removed = 0;
    for (final k in dedupKeys) {
      if (_byKey.remove(k) != null) removed++;
    }
    return removed;
  }

  @override
  Future<int> pruneOrphaned({
    String? activeFlightId,
    DateTime? now,
    Duration maxAge = FixUploadQueueStore.orphanedRetentionMaxAge,
    int maxFlights = FixUploadQueueStore.maxOrphanedFlights,
  }) async =>
      _pruneOrphanedUnlocked(
        _byKey,
        activeFlightId: activeFlightId,
        nowMs: (now ?? _clock()).millisecondsSinceEpoch,
        maxAge: maxAge,
        maxFlights: maxFlights,
      );

  @override
  Future<void> clear({String? flightId}) async {
    if (flightId == null) {
      _byKey.clear();
    } else {
      _byKey.removeWhere((_, v) => v.flightId == flightId);
    }
  }
}
