import 'dart:collection';

import 'package:latlong2/latlong.dart';

/// Maximum lookback window for the pilot's own local trail ("All" / `-1`).
const int maxOwnTrailWindowMinutes = 120;

/// Maximum number of local fixes kept in memory (~33 min at 1 Hz, or 120 min
/// when sparser; bounds RAM usage cleanly).
const int maxOwnTrailPoints = 2000;

/// Fallback window when neither per-flight override nor club default is known.
const int defaultFallbackTrailMinutes = 5;

/// A locally captured GPS fix from the device's tracking pipeline.
class LocalFix {
  const LocalFix({
    required this.timeMs,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.bearing,
    this.speed,
  });

  final int timeMs;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? bearing;
  final double? speed;

  LatLng get latLng => LatLng(latitude, longitude);

  bool get hasValidCoordinates =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90.0 &&
      latitude <= 90.0 &&
      longitude >= -180.0 &&
      longitude <= 180.0;

  static LocalFix? fromMap(Map<Object?, Object?> raw) {
    final timeRaw = raw['timeMs'];
    final latRaw = raw['lat'];
    final lonRaw = raw['lon'];
    if (timeRaw is! num || latRaw is! num || lonRaw is! num) return null;
    final fix = LocalFix(
      timeMs: timeRaw.toInt(),
      latitude: latRaw.toDouble(),
      longitude: lonRaw.toDouble(),
      altitude: raw['alt'] is num ? (raw['alt'] as num).toDouble() : null,
      bearing: raw['bearing'] is num ? (raw['bearing'] as num).toDouble() : null,
      speed: raw['speed'] is num ? (raw['speed'] as num).toDouble() : null,
    );
    return fix.hasValidCoordinates ? fix : null;
  }
}

/// Resolves the effective own-trail window in minutes (`0` = Off / marker only,
/// `1..120` = minutes to display).
///
/// Precedence:
/// 1. Pilot's per-flight override (`overrideMinutes`) if non-null.
/// 2. Club default (`clubDefaultMinutes`) if non-null.
/// 3. [defaultFallbackTrailMinutes] (`5`).
///
/// Encoding:
/// - `0` → Off (`0` minutes: show marker only).
/// - `-1` → All, capped at [maxOwnTrailWindowMinutes] (`120` minutes).
/// - `> 0` → clamped to `[1, maxOwnTrailWindowMinutes]`.
int resolveEffectiveTrailMinutes({
  required int? overrideMinutes,
  required int? clubDefaultMinutes,
}) {
  final raw = overrideMinutes ?? clubDefaultMinutes ?? defaultFallbackTrailMinutes;
  if (raw == 0) return 0;
  if (raw == -1) return maxOwnTrailWindowMinutes;
  if (raw < 0) return 0;
  return raw > maxOwnTrailWindowMinutes ? maxOwnTrailWindowMinutes : raw;
}

/// In-memory ring buffer storing the pilot's own local fixes for map rendering.
///
/// Never triggers network requests. Capped at [maxWindowMinutes] (default 120)
/// and [maxPoints] (default 2000).
class OwnTrailBuffer {
  OwnTrailBuffer({
    this.maxWindowMinutes = maxOwnTrailWindowMinutes,
    this.maxPoints = maxOwnTrailPoints,
  })  : assert(maxWindowMinutes > 0),
        assert(maxPoints > 0);

  final int maxWindowMinutes;
  final int maxPoints;
  final ListQueue<LocalFix> _fixes = ListQueue<LocalFix>();

  int get length => _fixes.length;
  bool get isEmpty => _fixes.isEmpty;
  LocalFix? get latestFix => _fixes.isEmpty ? null : _fixes.last;

  /// All buffered fixes in chronological order (oldest first).
  List<LocalFix> get allFixes => List<LocalFix>.unmodifiable(_fixes);

  /// Records [fix], returning `true` if the buffer changed.
  bool add(LocalFix fix) {
    if (!fix.hasValidCoordinates) return false;
    if (_fixes.isEmpty) {
      _fixes.addLast(fix);
      return true;
    }

    final last = _fixes.last;
    if (fix.timeMs == last.timeMs &&
        fix.latitude == last.latitude &&
        fix.longitude == last.longitude) {
      return false;
    }

    if (fix.timeMs >= last.timeMs) {
      if (fix.timeMs == last.timeMs) {
        _fixes.removeLast();
      }
      _fixes.addLast(fix);
    } else {
      // Out-of-order fix: drop if already outside the max retention window.
      final cutoff = last.timeMs - maxWindowMinutes * 60 * 1000;
      if (fix.timeMs < cutoff) return false;
      final ordered = _fixes.toList(growable: true);
      var insertAt = ordered.length;
      for (var i = ordered.length - 1; i >= 0; i--) {
        if (ordered[i].timeMs == fix.timeMs &&
            ordered[i].latitude == fix.latitude &&
            ordered[i].longitude == fix.longitude) {
          return false;
        }
        if (ordered[i].timeMs <= fix.timeMs) {
          insertAt = i + 1;
          break;
        }
        insertAt = i;
      }
      ordered.insert(insertAt, fix);
      _fixes
        ..clear()
        ..addAll(ordered);
    }

    _prune();
    return true;
  }

  /// Adds multiple fixes (e.g. synced from native buffer on resume).
  bool addAll(Iterable<LocalFix> fixes) {
    var changed = false;
    for (final fix in fixes) {
      if (add(fix)) changed = true;
    }
    return changed;
  }

  void clear() => _fixes.clear();

  void _prune() {
    if (_fixes.isEmpty) return;
    final cutoffMs = _fixes.last.timeMs - maxWindowMinutes * 60 * 1000;
    while (_fixes.isNotEmpty && _fixes.first.timeMs < cutoffMs) {
      _fixes.removeFirst();
    }
    while (_fixes.length > maxPoints) {
      _fixes.removeFirst();
    }
  }

  /// Returns the own-trail points within the pilot's effective window `X`.
  ///
  /// - When effective `X == 0` (Off), returns an empty list (marker-only).
  /// - When effective `X == -1` (All), caps lookback at 120 minutes.
  /// - When [nowMs] is omitted, anchors the lookback window at [latestFix]'s
  ///   timestamp (matching server `trail.rs` window semantics).
  List<LocalFix> windowedTrail({
    required int? overrideMinutes,
    required int? clubDefaultMinutes,
    int? nowMs,
  }) {
    if (_fixes.isEmpty) return const [];
    final effectiveMinutes = resolveEffectiveTrailMinutes(
      overrideMinutes: overrideMinutes,
      clubDefaultMinutes: clubDefaultMinutes,
    );
    if (effectiveMinutes <= 0) return const [];

    final anchorMs = nowMs ?? _fixes.last.timeMs;
    final cutoffMs = anchorMs - effectiveMinutes * 60 * 1000;
    final out = <LocalFix>[];
    for (final fix in _fixes) {
      if (fix.timeMs >= cutoffMs && fix.timeMs <= anchorMs) {
        out.add(fix);
      }
    }
    return out;
  }
}
