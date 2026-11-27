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

  /// Reserved internal folder for pre-#11 flat legacy files (`local_flights/*.json`).
  ///
  /// Never returned by [sanitizeBucket] or [bucketForPilotId], and never
  /// readable/writable through standard bucket APIs ([listFlights], [getFlight],
  /// [save], [deleteFlight], [moveFlights]).
  static const String legacyBucket = 'legacy';

  /// Returns [guestBucket] when signed out or not an approved account, else a
  /// stable, filesystem-safe hashed bucket derived from `pilot.id` (never email).
  static String bucketForPilot(PilotProfile? pilot) {
    if (pilot == null || !pilot.isApproved) return guestBucket;
    return bucketForPilotId(pilot.id);
  }

  /// Returns [guestBucket] when [pilotId] is null/empty, else a deterministic
  /// 128-bit hex hash bucket derived from [pilotId] (never plain-text email,
  /// and can never collide with [guestBucket] or [legacyBucket]).
  static String bucketForPilotId(String? pilotId) {
    final trimmed = pilotId?.trim() ?? '';
    if (trimmed.isEmpty) return guestBucket;
    return 'acct_${_stableAccountHashHex(trimmed)}';
  }

  static String _cleanBucketToken(String? bucket) {
    final trimmed = bucket?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return '';
    }
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  /// Returns true when [bucket] refers to a reserved internal bucket name
  /// (currently [legacyBucket], matched case-insensitively).
  static bool isReservedBucket(String? bucket) {
    final cleaned = _cleanBucketToken(bucket);
    return cleaned.toLowerCase() == legacyBucket;
  }

  /// Sanitizes an explicit bucket name to prevent path traversal and prevents
  /// any caller from targeting reserved buckets (such as [legacyBucket]).
  static String sanitizeBucket(String? bucket) {
    final cleaned = _cleanBucketToken(bucket);
    if (cleaned.isEmpty || cleaned.toLowerCase() == legacyBucket) {
      return guestBucket;
    }
    return cleaned;
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

  /// Moves flights from [fromBucket] into [toBucket], enforcing retention
  /// limits in [toBucket] and removing moved files from [fromBucket].
  ///
  /// When [flightIds] is provided, only flights whose `id` is in [flightIds]
  /// are moved. Refuses reserved buckets (returns `0`).
  /// Returns the number of flights moved.
  Future<int> moveFlights({
    required String fromBucket,
    required String toBucket,
    Set<String>? flightIds,
  });

  /// Returns the count of migrated pre-#11 legacy flights stored in the
  /// isolated `legacy/` folder. Never exposes legacy tracks to guest views.
  Future<int> countLegacyFlights();

  /// Moves all migrated legacy flights from `legacy/` into [toBucket],
  /// enforcing retention limits and removing moved files from `legacy/`.
  ///
  /// Throws [ArgumentError] if [toBucket] resolves to [guestBucket] or a
  /// reserved bucket. Returns the number of flights moved.
  Future<int> adoptLegacyFlights({required String toBucket});

  /// Permanently deletes all migrated legacy flight files from `legacy/`.
  /// Returns the number of legacy files deleted.
  Future<int> deleteLegacyFlights();

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
/// files from earlier builds into the isolated reserved folder
/// `<appDocumentsDir>/local_flights/legacy/` on first access (never `guest/`).
class FileLocalFlightStore implements LocalFlightStore {
  FileLocalFlightStore({
    Future<Directory> Function()? directoryProvider,
    String defaultBucket = LocalFlightStore.guestBucket,
  })  : _directoryProvider = directoryProvider ?? getApplicationDocumentsDirectory,
        _defaultBucket = LocalFlightStore.sanitizeBucket(defaultBucket);

  final Future<Directory> Function() _directoryProvider;
  final String _defaultBucket;
  Future<void>? _legacyMigrationFuture;

  String _resolveBucket(String? bucket) =>
      bucket == null ? _defaultBucket : LocalFlightStore.sanitizeBucket(bucket);

  Future<Directory> _rootDir() async {
    final base = await _directoryProvider();
    final root = Directory('${base.path}${Platform.pathSeparator}local_flights');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final pending = _legacyMigrationFuture ??= _migrateLegacyRootFiles(root);
    try {
      await pending;
    } catch (_) {
      _legacyMigrationFuture = null;
      rethrow;
    }
    return root;
  }

  Future<Directory> _legacyDir({bool create = false}) async {
    final root = await _rootDir();
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}${LocalFlightStore.legacyBucket}',
    );
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _migrateLegacyRootFiles(Directory root) async {
    final legacyFiles = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) {
        legacyFiles.add(entity);
      }
    }
    if (legacyFiles.isEmpty) return;
    final legacyDir = Directory(
      '${root.path}${Platform.pathSeparator}${LocalFlightStore.legacyBucket}',
    );
    if (!await legacyDir.exists()) {
      await legacyDir.create(recursive: true);
    }
    for (final file in legacyFiles) {
      final sep = Platform.pathSeparator;
      final fileName = file.path.split(sep).last;
      final destPath = '${legacyDir.path}$sep$fileName';
      final dest = File(destPath);
      if (await dest.exists()) {
        // Keep already-migrated legacy copy and remove legacy root duplicate.
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
    await _pruneOverflowDir(legacyDir);
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
    Set<String>? flightIds,
  }) async {
    if (LocalFlightStore.isReservedBucket(fromBucket) ||
        LocalFlightStore.isReservedBucket(toBucket)) {
      return 0;
    }
    final sourceBucket = LocalFlightStore.sanitizeBucket(fromBucket);
    final targetBucket = LocalFlightStore.sanitizeBucket(toBucket);
    if (sourceBucket == targetBucket) return 0;

    final sourceDir = await _bucketDir(sourceBucket, create: false);
    if (!await sourceDir.exists()) return 0;

    final allFlights = await _readDirFlights(sourceDir);
    final flights = flightIds == null
        ? allFlights
        : allFlights.where((f) => flightIds.contains(f.id)).toList();
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

  @override
  Future<int> countLegacyFlights() async {
    final dir = await _legacyDir(create: false);
    final flights = await _readDirFlights(dir);
    return flights.length;
  }

  @override
  Future<int> adoptLegacyFlights({required String toBucket}) async {
    if (LocalFlightStore.isReservedBucket(toBucket)) {
      throw ArgumentError.value(
        toBucket,
        'toBucket',
        'Cannot adopt legacy flights into reserved bucket',
      );
    }
    final targetBucket = LocalFlightStore.sanitizeBucket(toBucket);
    if (targetBucket == LocalFlightStore.guestBucket) {
      throw ArgumentError.value(
        toBucket,
        'toBucket',
        'Cannot adopt legacy flights into guest bucket',
      );
    }

    final legacyDir = await _legacyDir(create: false);
    if (!await legacyDir.exists()) return 0;

    final flights = await _readDirFlights(legacyDir);
    if (flights.isEmpty) return 0;

    final targetDir = await _bucketDir(targetBucket, create: true);
    var moved = 0;
    for (final flight in flights) {
      final fileName = _safeFileName(flight.id);
      final srcFile = File('${legacyDir.path}${Platform.pathSeparator}$fileName');
      final dstPath = '${targetDir.path}${Platform.pathSeparator}$fileName';
      if (!await srcFile.exists()) continue;
      final dstFile = File(dstPath);
      if (await dstFile.exists()) {
        // Keep existing account copy and remove legacy duplicate.
        try {
          await srcFile.delete();
          moved++;
        } catch (_) {}
        continue;
      }
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
    await _removeLegacyDirIfEmpty(legacyDir);
    return moved;
  }

  @override
  Future<int> deleteLegacyFlights() async {
    final legacyDir = await _legacyDir(create: false);
    if (!await legacyDir.exists()) return 0;
    var deleted = 0;
    await for (final entity in legacyDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final isJson = entity.path.endsWith('.json');
      final isTmp = entity.path.endsWith('.json.tmp');
      if (!isJson && !isTmp) continue;
      try {
        await entity.delete();
        if (isJson) deleted++;
      } catch (_) {}
    }
    await _removeLegacyDirIfEmpty(legacyDir);
    return deleted;
  }

  Future<void> _removeLegacyDirIfEmpty(Directory legacyDir) async {
    try {
      if (await legacyDir.exists() && await legacyDir.list().isEmpty) {
        await legacyDir.delete();
      }
    } catch (_) {}
  }
}

/// Deterministic in-memory [LocalFlightStore] with per-account bucket isolation
/// and a separate reserved legacy pool for unit/widget/golden tests.
class InMemoryLocalFlightStore implements LocalFlightStore {
  InMemoryLocalFlightStore({
    List<LocalFlight> initial = const [],
    String initialBucket = LocalFlightStore.guestBucket,
    String defaultBucket = LocalFlightStore.guestBucket,
    List<LocalFlight> initialLegacy = const [],
  }) : _defaultBucket = LocalFlightStore.sanitizeBucket(defaultBucket) {
    final bucket = LocalFlightStore.sanitizeBucket(initialBucket);
    if (initial.isNotEmpty) {
      final map = _byBucket.putIfAbsent(bucket, () => {});
      for (final f in initial) {
        map[f.id] = f;
      }
    }
    for (final f in initialLegacy) {
      _legacy[f.id] = f;
    }
  }

  final String _defaultBucket;
  final Map<String, Map<String, LocalFlight>> _byBucket = {};
  final Map<String, LocalFlight> _legacy = {};

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
    Set<String>? flightIds,
  }) async {
    if (LocalFlightStore.isReservedBucket(fromBucket) ||
        LocalFlightStore.isReservedBucket(toBucket)) {
      return 0;
    }
    final source = LocalFlightStore.sanitizeBucket(fromBucket);
    final target = LocalFlightStore.sanitizeBucket(toBucket);
    if (source == target) return 0;
    final srcMap = _byBucket[source];
    if (srcMap == null || srcMap.isEmpty) return 0;
    final idsToMove = flightIds == null
        ? srcMap.keys.toList()
        : srcMap.keys.where(flightIds.contains).toList();
    if (idsToMove.isEmpty) return 0;
    final dstMap = _byBucket.putIfAbsent(target, () => {});
    for (final id in idsToMove) {
      final flight = srcMap.remove(id);
      if (flight != null) {
        dstMap[id] = flight;
      }
    }
    await _pruneBucket(target);
    return idsToMove.length;
  }

  @override
  Future<int> countLegacyFlights() async => _legacy.length;

  @override
  Future<int> adoptLegacyFlights({required String toBucket}) async {
    if (LocalFlightStore.isReservedBucket(toBucket)) {
      throw ArgumentError.value(
        toBucket,
        'toBucket',
        'Cannot adopt legacy flights into reserved bucket',
      );
    }
    final target = LocalFlightStore.sanitizeBucket(toBucket);
    if (target == LocalFlightStore.guestBucket) {
      throw ArgumentError.value(
        toBucket,
        'toBucket',
        'Cannot adopt legacy flights into guest bucket',
      );
    }
    if (_legacy.isEmpty) return 0;
    final dstMap = _byBucket.putIfAbsent(target, () => {});
    final moved = _legacy.length;
    for (final entry in _legacy.entries) {
      dstMap.putIfAbsent(entry.key, () => entry.value);
    }
    _legacy.clear();
    await _pruneBucket(target);
    return moved;
  }

  @override
  Future<int> deleteLegacyFlights() async {
    final deleted = _legacy.length;
    _legacy.clear();
    return deleted;
  }
}
