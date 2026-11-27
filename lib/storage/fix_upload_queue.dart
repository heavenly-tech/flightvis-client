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

/// Persisted fix awaiting batch upload to `POST /api/ingest`.
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
  });

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
    );
  }
}

/// Persistent store-and-forward queue for broadcast fixes awaiting batch upload.
abstract class FixUploadQueueStore {
  static const int maxBatchSize = 100;
  static const int maxQueuedFixes = 50000;

  /// Adds [fix] if its `(flightId, tMs)` key is not already present.
  /// Returns `true` when newly enqueued, `false` when deduplicated or invalid.
  Future<bool> enqueue(QueuedFixInput fix);

  /// Adds all valid, non-duplicate fixes in [fixes]. Returns number added.
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes);

  /// Returns all pending fixes ordered oldest-first (`tMs` asc, `seq` asc).
  Future<List<QueuedFix>> listAll();

  /// Returns the number of queued fixes currently pending upload.
  Future<int> count();

  /// Peeks up to [maxCount] (clamped to `1..maxBatchSize`) oldest fixes for the
  /// oldest queued flight (so every batch shares a single `flightId` and
  /// `flightMode` / bearer token).
  Future<List<QueuedFix>> peekOldestBatch({int maxCount = maxBatchSize});

  /// Removes ONLY entries whose `dedupKey` is in [dedupKeys] (called after a
  /// 2xx response covering those fixes, or when dropping a single unsplitable
  /// oversized fix).
  Future<int> removeKeys(Iterable<String> dedupKeys);

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

/// Disk-backed [FixUploadQueueStore] persisting atomically to
/// `<appDocumentsDir>/upload_queue/<accountBucket>/queue.json`.
class FileFixUploadQueueStore implements FixUploadQueueStore {
  FileFixUploadQueueStore({
    Future<Directory> Function()? directoryProvider,
    String accountBucket = LocalFlightStore.guestBucket,
    int maxFixes = FixUploadQueueStore.maxQueuedFixes,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _accountBucket = LocalFlightStore.sanitizeBucket(accountBucket),
        _maxFixes = maxFixes;

  final Future<Directory> Function() _directoryProvider;
  final String _accountBucket;
  final int _maxFixes;

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
      'version': 1,
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

  bool _insertUnlocked(QueuedFixInput input) {
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
    );
    return true;
  }

  @override
  Future<bool> enqueue(QueuedFixInput fix) => _serialized(() async {
        await _ensureLoaded();
        final added = _insertUnlocked(fix);
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
        var added = 0;
        for (final fix in fixes) {
          if (_insertUnlocked(fix)) added++;
        }
        if (added > 0) {
          _enforceCap();
          await _persist();
        }
        return added;
      });

  @override
  Future<List<QueuedFix>> listAll() => _serialized(() async {
        await _ensureLoaded();
        final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
        return List<QueuedFix>.unmodifiable(ordered);
      });

  @override
  Future<int> count() => _serialized(() async {
        await _ensureLoaded();
        return _byKey.length;
      });

  @override
  Future<List<QueuedFix>> peekOldestBatch({
    int maxCount = FixUploadQueueStore.maxBatchSize,
  }) =>
      _serialized(() async {
        await _ensureLoaded();
        if (_byKey.isEmpty) return const [];
        final cap = maxCount.clamp(1, FixUploadQueueStore.maxBatchSize);
        final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
        final headFlightId = ordered.first.flightId;
        final headMode = ordered.first.flightMode;
        final batch = <QueuedFix>[];
        for (final fix in ordered) {
          if (fix.flightId != headFlightId || fix.flightMode != headMode) {
            continue;
          }
          batch.add(fix);
          if (batch.length >= cap) break;
        }
        return List<QueuedFix>.unmodifiable(batch);
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
  }) : _maxFixes = maxFixes;

  final int _maxFixes;
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

  bool _insert(QueuedFixInput input) {
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
    );
    return true;
  }

  @override
  Future<bool> enqueue(QueuedFixInput fix) async {
    final added = _insert(fix);
    if (added) _enforceCap();
    return added;
  }

  @override
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes) async {
    var added = 0;
    for (final f in fixes) {
      if (_insert(f)) added++;
    }
    if (added > 0) _enforceCap();
    return added;
  }

  @override
  Future<List<QueuedFix>> listAll() async {
    final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
    return List<QueuedFix>.unmodifiable(ordered);
  }

  @override
  Future<int> count() async => _byKey.length;

  @override
  Future<List<QueuedFix>> peekOldestBatch({
    int maxCount = FixUploadQueueStore.maxBatchSize,
  }) async {
    if (_byKey.isEmpty) return const [];
    final cap = maxCount.clamp(1, FixUploadQueueStore.maxBatchSize);
    final ordered = _byKey.values.toList()..sort(_compareQueuedFix);
    final headFlightId = ordered.first.flightId;
    final headMode = ordered.first.flightMode;
    final batch = <QueuedFix>[];
    for (final fix in ordered) {
      if (fix.flightId != headFlightId || fix.flightMode != headMode) continue;
      batch.add(fix);
      if (batch.length >= cap) break;
    }
    return List<QueuedFix>.unmodifiable(batch);
  }

  @override
  Future<int> removeKeys(Iterable<String> dedupKeys) async {
    var removed = 0;
    for (final k in dedupKeys) {
      if (_byKey.remove(k) != null) removed++;
    }
    return removed;
  }

  @override
  Future<void> clear({String? flightId}) async {
    if (flightId == null) {
      _byKey.clear();
    } else {
      _byKey.removeWhere((_, v) => v.flightId == flightId);
    }
  }
}
