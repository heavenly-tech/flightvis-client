import '../map/own_trail_buffer.dart';

/// On-device recorded flight ready for future upload (no upload network call
/// is made in 1.4.0).
class LocalFlight {
  const LocalFlight({
    required this.id,
    required this.startedAtMs,
    required this.endedAtMs,
    this.tail,
    required this.fixes,
    this.uploaded = false,
  });

  static const int maxTailLength = 16;
  static const int maxFixesPerFlight = 20000;

  final String id;
  final int startedAtMs;
  final int endedAtMs;

  /// Optional sanitized uppercase tail label (`[A-Z0-9-]`, max 16 chars).
  final String? tail;

  /// Chronological fixes `[t_ms, lat, lon, alt|null]`, capped at
  /// [maxFixesPerFlight].
  final List<LocalFix> fixes;

  /// Reserved hook for a future upload PR (`club-less app F`).
  final bool uploaded;

  Duration get duration {
    final diff = endedAtMs - startedAtMs;
    return Duration(milliseconds: diff < 0 ? 0 : diff);
  }

  /// Normalizes free-text tail input to uppercase `[A-Z0-9-]`, max 16 chars.
  /// Returns `null` when empty.
  static String? sanitizeTail(String? raw) {
    if (raw == null) return null;
    final upper = raw.trim().toUpperCase();
    final filtered = upper.replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    if (filtered.isEmpty) return null;
    if (filtered.length <= maxTailLength) return filtered;
    return filtered.substring(0, maxTailLength);
  }

  /// Trims [fixes] to at most [maxFixesPerFlight], keeping the most recent
  /// fixes in chronological order.
  static List<LocalFix> capFixes(List<LocalFix> fixes) {
    final valid = fixes.where((f) => f.hasValidCoordinates).toList();
    if (valid.length <= maxFixesPerFlight) {
      return List<LocalFix>.unmodifiable(valid);
    }
    return List<LocalFix>.unmodifiable(
      valid.sublist(valid.length - maxFixesPerFlight),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAtMs': startedAtMs,
        'endedAtMs': endedAtMs,
        if (tail != null) 'tail': tail,
        'uploaded': uploaded,
        'fixes': [
          for (final f in fixes) [f.timeMs, f.latitude, f.longitude, f.altitude],
        ],
      };

  static LocalFlight? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final startedAt = (json['startedAtMs'] as num?)?.toInt();
    final endedAt = (json['endedAtMs'] as num?)?.toInt();
    if (id == null || id.isEmpty || startedAt == null || endedAt == null) {
      return null;
    }
    final rawFixes = json['fixes'] as List<dynamic>? ?? const [];
    final parsedFixes = <LocalFix>[];
    for (final item in rawFixes) {
      if (item is List && item.length >= 3) {
        final t = item[0];
        final lat = item[1];
        final lon = item[2];
        if (t is num && lat is num && lon is num) {
          final altRaw = item.length >= 4 ? item[3] : null;
          final alt =
              altRaw is num && altRaw.toDouble().isFinite ? altRaw.toDouble() : null;
          final fix = LocalFix(
            timeMs: t.toInt(),
            latitude: lat.toDouble(),
            longitude: lon.toDouble(),
            altitude: alt,
          );
          if (fix.hasValidCoordinates) parsedFixes.add(fix);
        }
      }
    }
    return LocalFlight(
      id: id,
      startedAtMs: startedAt,
      endedAtMs: endedAt,
      tail: sanitizeTail(json['tail'] as String?),
      fixes: capFixes(parsedFixes),
      uploaded: json['uploaded'] == true,
    );
  }

  // TODO(club-less-app-f): Add upload serializer/hook once server non-club
  // flight upload API is implemented.
}
