import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../api/flight_vis_client.dart';
import '../models/local_flight.dart';

/// Persistent store for locally recorded flights on the device, scoped per
/// account bucket (`guest` when signed out, or a hashed pilot-ID bucket when
/// signed in).
///
/// Designed as a clean seam so a future "club-less app F" PR can stack upload
/// tracking on top without modifying UI or recorder code.
abstract class LocalFlightStore {
  static const int maxStoredFlights = 50;
  static const String guestBucket = 'guest';

  /// Returns [guestBucket] when signed out or not an approved account, else a
  /// stable, filesystem-safe hashed bucket derived from `pilot.id` (never email).
  static String bucketForPilot(PilotProfile? pilot) {
    if (pilot == null || !pilot.isApproved) return guestBucket;
    return bucketForPilotId(pilot.id);
  }

  /// Returns [guestBucket] when [pilotId] is null/empty, else a deterministic
  /// 128-bit hex hash bucket derived from [pilotId] (never plain-text email).
  static String bucketForPilotId(String? pilotId) {
    final trimmed = pilotId?.trim() ?? '';
    if (trimmed.isEmpty) return guestBucket;
    return 'acct_${_stableAccountHashHex(trimmed)}';
  }

  /// Sanitizes an explicit bucket name to prevent path traversal.
  static String sanitizeBucket(String? bucket) {
    final trimmed = bucket?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return guestBucket;
    }
    final cleaned = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? guestBucket : cleaned;
  }

  /// Saves (or replaces) [flight] into [bucket] (defaulting to the store's
  /// default bucket), enforcing fix and flight count caps per bucket.
  Future<void> save(LocalFlight flight, {String? bucket});

  /// Lists stored flights in [bucket] ordered newest-first (`startedAtMs` desc).
  Future<List<LocalFlight>> listFlights({String? bucket});

  /// Loads a single flight by [id] from [bucket], or `null` if missing.
  Future<LocalFlight?> getFlight(String id, {String? bucket});

  /// Deletes a single stored flight by [id] from [bucket].
  Future<void> deleteFlight(String id, {String? bucket});

  /// Moves all flights from [fromBucket] into [toBucket], enforcing retention
  /// limits in [toBucket] and removing moved files from [fromBucket].
  /// Returns the number of flights moved.
  Future<int> moveFlights({
    required String fromBucket,
    required String toBucket,
  });

  // TODO(club-less-app-f): Future<void> markUploaded(String id, String remoteId);
}

/// Deterministic 128-bit hash of UTF-8 input into 32 lowercase hex characters
/// using four independent 32-bit mixing lanes (zero external dependencies).
String _stableAccountHashHex(String input) {
  final bytes = utf8.encode(input);
  var h0 = 0x811c9dc5;
  var h1 = 0x9e3779b1;
  var h2 = 0x85ebca77;
  var h3 = 0xc2b2ae3d;

  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    h0 = ((h0 ^ b) * 0x01000193) & 0xffffffff;
    h1 = (((h1 + b + (i & 0xff)) * 0x27d4eb2d) ^ (h0 >>> 7)) & 0xffffffff;
    h2 = (((h2 ^ (b + 0x55)) * 0x165667b1) + (h1 >>> 11)) & 0xffffffff;
    h3 = (((h3 + (b * 31) + 1) * 0x9e3779b9) ^ (h2 >>> 13)) & 0xffffffff;
  }

  int finalize(int v) {
    var x = (v ^ (bytes.length & 0xffffffff)) & 0xffffffff;
    x = ((x ^ (x >>> 16)) * 0x7feb352d) & 0xffffffff;
    x = ((x ^ (x >>> 15)) * 0x846ca68b) & 0xffffffff;
    return (x ^ (x >>> 16)) & 0xffffffff;
  }

  final words = [finalize(h0), finalize(h1), finalize(h2), finalize(h3)];
  final buf = StringBuffer();
  for (final w in words) {
    buf.write(w.toRadixString(16).padLeft(8, '0'));
  }
  return buf.toString();
}

/// File-backed [LocalFlightStore] writing one JSON file per flight under
/// `<appDocumentsDir>/local_flights/<bucket>/<id>.json`.
///
/// Automatically migrates legacy un-bucketed `<appDocumentsDir>/local_flights/*.json`
/// files from earlier builds into `<appDocumentsDir>/local_flights/guest/` on
/// first access.
class FileLocalFlightStore implements LocalFlightStore {
  FileLocalFlightStore({
    Future<Directory> Function()? directoryProvider,
    String defaultBucket = LocalFlightStore.guestBucket,
  })  : _directoryProvider = directoryProvider ?? getApplicationDocumentsDirectory,
        _defaultBucket = LocalFlightStore.sanitizeBucket(defaultBucket);

  final Future<Directory> Function() _directoryProvider;
  final String _defaultBucket;
  bool _legacyMigrated = false;

  String _resolveBucket(String? bucket) =>
      bucket == null ? _defaultBucket : LocalFlightStore.sanitizeBucket(bucket);

  Future<Directory> _rootDir() async {
    final base = await _directoryProvider();
    final root = Directory('${base.path}${Platform.pathSeparator}local_flights');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    if (!_legacyMigrated) {
      await _migrateLegacyRootFiles(root);
      _legacyMigrated = true;
    }
    return root;
  }

  Future<void> _migrateLegacyRootFiles(Directory root) async {
    final legacyFiles = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) {
        legacyFiles.add(entity);
      }
    }
    if (legacyFiles.isEmpty) return;
    final guestDir = Directory(
      '${root.path}${Platform.pathSeparator}${LocalFlightStore.guestBucket}',
    );
    if (!await guestDir.exists()) {
      await guestDir.create(recursive: true);
    }
    for (final file in legacyFiles) {
      final sep = Platform.pathSeparator;
      final fileName = file.path.split(sep).last;
      final destPath = '${guestDir.path}$sep$fileName';
      final dest = File(destPath);
      if (await dest.exists()) {
        // Keep already-migrated guest copy and remove legacy root duplicate.
        try {
          await file.delete();
        } catch (_) {}
        continue;
      }
      try {
        await file.rename(destPath);
      } catch (_) {
        try {
          await file.copy(destPath);
          await file.delete();
        } catch (_) {}
      }
    }
    await _pruneOverflowDir(guestDir);
  }

  Future<Directory> _bucketDir(String bucket, {bool create = true}) async {
    final root = await _rootDir();
    final safeBucket = LocalFlightStore.sanitizeBucket(bucket);
    final dir = Directory('${root.path}${Platform.pathSeparator}$safeBucket');
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeFileName(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$safe.json';
  }

  @override
  Future<void> save(LocalFlight flight, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final dir = await _bucketDir(resolved);
    final capped = LocalFlight(
      id: flight.id,
      startedAtMs: flight.startedAtMs,
      endedAtMs: flight.endedAtMs,
      tail: LocalFlight.sanitizeTail(flight.tail),
      fixes: LocalFlight.capFixes(flight.fixes),
      uploaded: flight.uploaded,
    );
    final filePath =
        '${dir.path}${Platform.pathSeparator}${_safeFileName(capped.id)}';
    final tmpFile = File('$filePath.tmp');
    await tmpFile.writeAsString(jsonEncode(capped.toJson()), flush: true);
    await tmpFile.rename(filePath);
    await _pruneOverflowDir(dir);
  }

  Future<List<LocalFlight>> _readDirFlights(Directory dir) async {
    if (!await dir.exists()) return const [];
    final out = <LocalFlight>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final flight = LocalFlight.fromJson(decoded);
          if (flight != null) out.add(flight);
        }
      } catch (_) {
        // Ignore corrupt/partial files cleanly.
      }
    }
    out.sort((a, b) {
      final byStart = b.startedAtMs.compareTo(a.startedAtMs);
      if (byStart != 0) return byStart;
      return b.id.compareTo(a.id);
    });
    return out;
  }

  Future<void> _pruneOverflowDir(Directory dir) async {
    final flights = await _readDirFlights(dir);
    if (flights.length <= LocalFlightStore.maxStoredFlights) return;
    final toDelete = flights.sublist(LocalFlightStore.maxStoredFlights);
    for (final old in toDelete) {
      final f = File('${dir.path}${Platform.pathSeparator}${_safeFileName(old.id)}');
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  @override
  Future<List<LocalFlight>> listFlights({String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final dir = await _bucketDir(resolved, create: false);
    return _readDirFlights(dir);
  }

  @override
  Future<LocalFlight?> getFlight(String id, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final dir = await _bucketDir(resolved, create: false);
    if (!await dir.exists()) return null;
    final file = File('${dir.path}${Platform.pathSeparator}${_safeFileName(id)}');
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return LocalFlight.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> deleteFlight(String id, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final dir = await _bucketDir(resolved, create: false);
    if (!await dir.exists()) return;
    final file = File('${dir.path}${Platform.pathSeparator}${_safeFileName(id)}');
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<int> moveFlights({
    required String fromBucket,
    required String toBucket,
  }) async {
    final sourceBucket = LocalFlightStore.sanitizeBucket(fromBucket);
    final targetBucket = LocalFlightStore.sanitizeBucket(toBucket);
    if (sourceBucket == targetBucket) return 0;

    final sourceDir = await _bucketDir(sourceBucket, create: false);
    if (!await sourceDir.exists()) return 0;

    final flights = await _readDirFlights(sourceDir);
    if (flights.isEmpty) return 0;

    final targetDir = await _bucketDir(targetBucket, create: true);
    var moved = 0;
    for (final flight in flights) {
      final fileName = _safeFileName(flight.id);
      final srcFile = File('${sourceDir.path}${Platform.pathSeparator}$fileName');
      final dstPath = '${targetDir.path}${Platform.pathSeparator}$fileName';
      if (!await srcFile.exists()) continue;
      try {
        await srcFile.rename(dstPath);
        moved++;
      } catch (_) {
        try {
          await srcFile.copy(dstPath);
          await srcFile.delete();
          moved++;
        } catch (_) {}
      }
    }
    await _pruneOverflowDir(targetDir);
    return moved;
  }
}

/// Deterministic in-memory [LocalFlightStore] with per-account bucket isolation
/// for unit/widget/golden tests.
class InMemoryLocalFlightStore implements LocalFlightStore {
  InMemoryLocalFlightStore({
    List<LocalFlight> initial = const [],
    String initialBucket = LocalFlightStore.guestBucket,
    String defaultBucket = LocalFlightStore.guestBucket,
  }) : _defaultBucket = LocalFlightStore.sanitizeBucket(defaultBucket) {
    final bucket = LocalFlightStore.sanitizeBucket(initialBucket);
    if (initial.isNotEmpty) {
      final map = _byBucket.putIfAbsent(bucket, () => {});
      for (final f in initial) {
        map[f.id] = f;
      }
    }
  }

  final String _defaultBucket;
  final Map<String, Map<String, LocalFlight>> _byBucket = {};

  String _resolveBucket(String? bucket) =>
      bucket == null ? _defaultBucket : LocalFlightStore.sanitizeBucket(bucket);

  @override
  Future<void> save(LocalFlight flight, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final map = _byBucket.putIfAbsent(resolved, () => {});
    map[flight.id] = LocalFlight(
      id: flight.id,
      startedAtMs: flight.startedAtMs,
      endedAtMs: flight.endedAtMs,
      tail: LocalFlight.sanitizeTail(flight.tail),
      fixes: LocalFlight.capFixes(flight.fixes),
      uploaded: flight.uploaded,
    );
    await _pruneBucket(resolved);
  }

  Future<void> _pruneBucket(String bucket) async {
    final map = _byBucket[bucket];
    if (map == null || map.length <= LocalFlightStore.maxStoredFlights) return;
    final ordered = await listFlights(bucket: bucket);
    for (final old in ordered.sublist(LocalFlightStore.maxStoredFlights)) {
      map.remove(old.id);
    }
  }

  @override
  Future<List<LocalFlight>> listFlights({String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    final map = _byBucket[resolved];
    if (map == null || map.isEmpty) return const [];
    final list = map.values.toList();
    list.sort((a, b) {
      final byStart = b.startedAtMs.compareTo(a.startedAtMs);
      if (byStart != 0) return byStart;
      return b.id.compareTo(a.id);
    });
    return list;
  }

  @override
  Future<LocalFlight?> getFlight(String id, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    return _byBucket[resolved]?[id];
  }

  @override
  Future<void> deleteFlight(String id, {String? bucket}) async {
    final resolved = _resolveBucket(bucket);
    _byBucket[resolved]?.remove(id);
  }

  @override
  Future<int> moveFlights({
    required String fromBucket,
    required String toBucket,
  }) async {
    final source = LocalFlightStore.sanitizeBucket(fromBucket);
    final target = LocalFlightStore.sanitizeBucket(toBucket);
    if (source == target) return 0;
    final srcMap = _byBucket[source];
    if (srcMap == null || srcMap.isEmpty) return 0;
    final dstMap = _byBucket.putIfAbsent(target, () => {});
    final moved = srcMap.length;
    dstMap.addAll(srcMap);
    srcMap.clear();
    await _pruneBucket(target);
    return moved;
  }
}
