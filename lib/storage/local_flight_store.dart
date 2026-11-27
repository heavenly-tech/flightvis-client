import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/local_flight.dart';

/// Persistent store for locally recorded flights on the device.
///
/// Designed as a clean seam so a future "club-less app F" PR can stack upload
/// tracking on top without modifying UI or recorder code.
abstract class LocalFlightStore {
  static const int maxStoredFlights = 50;

  /// Saves (or replaces) [flight], enforcing fix and flight count caps.
  Future<void> save(LocalFlight flight);

  /// Lists stored flights ordered newest-first (`startedAtMs` descending).
  Future<List<LocalFlight>> listFlights();

  /// Loads a single flight by [id], or `null` if missing.
  Future<LocalFlight?> getFlight(String id);

  /// Deletes a single stored flight by [id].
  Future<void> deleteFlight(String id);

  // TODO(club-less-app-f): Future<void> markUploaded(String id, String remoteId);
}

/// File-backed [LocalFlightStore] writing one JSON file per flight under
/// `<appDocumentsDir>/local_flights/<id>.json`.
class FileLocalFlightStore implements LocalFlightStore {
  FileLocalFlightStore({
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<Directory> _flightsDir() async {
    final base = await _directoryProvider();
    final dir = Directory('${base.path}${Platform.pathSeparator}local_flights');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeFileName(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$safe.json';
  }

  @override
  Future<void> save(LocalFlight flight) async {
    final dir = await _flightsDir();
    final capped = LocalFlight(
      id: flight.id,
      startedAtMs: flight.startedAtMs,
      endedAtMs: flight.endedAtMs,
      tail: LocalFlight.sanitizeTail(flight.tail),
      fixes: LocalFlight.capFixes(flight.fixes),
      uploaded: flight.uploaded,
    );
    final filePath = '${dir.path}${Platform.pathSeparator}${_safeFileName(capped.id)}';
    final tmpFile = File('$filePath.tmp');
    await tmpFile.writeAsString(jsonEncode(capped.toJson()), flush: true);
    await tmpFile.rename(filePath);
    await _pruneOverflow(dir);
  }

  Future<void> _pruneOverflow(Directory dir) async {
    final flights = await listFlights();
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
  Future<List<LocalFlight>> listFlights() async {
    final dir = await _flightsDir();
    final out = <LocalFlight>[];
    await for (final entity in dir.list()) {
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

  @override
  Future<LocalFlight?> getFlight(String id) async {
    final dir = await _flightsDir();
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
  Future<void> deleteFlight(String id) async {
    final dir = await _flightsDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_safeFileName(id)}');
    if (await file.exists()) {
      await file.delete();
    }
  }
}

/// Deterministic in-memory [LocalFlightStore] for unit/widget/golden tests.
class InMemoryLocalFlightStore implements LocalFlightStore {
  InMemoryLocalFlightStore({List<LocalFlight> initial = const []}) {
    for (final f in initial) {
      _flights[f.id] = f;
    }
  }

  final Map<String, LocalFlight> _flights = {};

  @override
  Future<void> save(LocalFlight flight) async {
    _flights[flight.id] = LocalFlight(
      id: flight.id,
      startedAtMs: flight.startedAtMs,
      endedAtMs: flight.endedAtMs,
      tail: LocalFlight.sanitizeTail(flight.tail),
      fixes: LocalFlight.capFixes(flight.fixes),
      uploaded: flight.uploaded,
    );
    final ordered = await listFlights();
    if (ordered.length > LocalFlightStore.maxStoredFlights) {
      for (final old in ordered.sublist(LocalFlightStore.maxStoredFlights)) {
        _flights.remove(old.id);
      }
    }
  }

  @override
  Future<List<LocalFlight>> listFlights() async {
    final list = _flights.values.toList();
    list.sort((a, b) {
      final byStart = b.startedAtMs.compareTo(a.startedAtMs);
      if (byStart != 0) return byStart;
      return b.id.compareTo(a.id);
    });
    return list;
  }

  @override
  Future<LocalFlight?> getFlight(String id) async => _flights[id];

  @override
  Future<void> deleteFlight(String id) async {
    _flights.remove(id);
  }
}
