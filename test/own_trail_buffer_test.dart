import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/map/trail_styles.dart';

void main() {
  group('resolveEffectiveTrailMinutes', () {
    test('uses override when provided, else club default, else fallback 5 min', () {
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: 15, clubDefaultMinutes: 5),
        15,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: null, clubDefaultMinutes: 10),
        10,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: null, clubDefaultMinutes: null),
        defaultFallbackTrailMinutes,
      );
    });

    test('maps 0 to Off (0) and -1 to All capped at 120 min', () {
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: 0, clubDefaultMinutes: 10),
        0,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: null, clubDefaultMinutes: 0),
        0,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: -1, clubDefaultMinutes: 5),
        120,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: null, clubDefaultMinutes: -1),
        120,
      );
      expect(
        resolveEffectiveTrailMinutes(overrideMinutes: 240, clubDefaultMinutes: 5),
        120,
      );
    });
  });

  group('OwnTrailBuffer windowing and caps', () {
    const baseMs = 1_700_000_000_000;
    const minMs = 60 * 1000;

    LocalFix fixAt(int minutesOffset) => LocalFix(
          timeMs: baseMs + minutesOffset * minMs,
          latitude: -33.45 + minutesOffset * 0.0005,
          longitude: -70.55 + minutesOffset * 0.0005,
        );

    test('cuts off fixes by X, Off returns empty trail while keeping latestFix, All caps at 120 min', () {
      final buffer = OwnTrailBuffer();
      // Add fixes spanning 0..150 minutes (151 fixes, 1 per minute).
      for (var m = 0; m <= 150; m++) {
        buffer.add(fixAt(m));
      }

      // Buffer itself prunes anything > 120 min before the latest fix (m=150).
      expect(buffer.allFixes.first.timeMs, baseMs + 30 * minMs);
      expect(buffer.latestFix?.timeMs, baseMs + 150 * minMs);

      // X = 5 min -> keeps m = 145..150 (6 points).
      final w5 = buffer.windowedTrail(overrideMinutes: 5, clubDefaultMinutes: 10);
      expect(w5.map((f) => (f.timeMs - baseMs) ~/ minMs).toList(), [145, 146, 147, 148, 149, 150]);

      // X = 0 (Off) -> empty trail polyline, latestFix preserved for own marker.
      final wOff = buffer.windowedTrail(overrideMinutes: 0, clubDefaultMinutes: 10);
      expect(wOff, isEmpty);
      expect(buffer.latestFix, isNotNull);
      expect(buffer.latestFix!.timeMs, baseMs + 150 * minMs);

      // X = -1 (All) -> capped at 120 min (m = 30..150 -> 121 points).
      final wAll = buffer.windowedTrail(overrideMinutes: -1, clubDefaultMinutes: 5);
      expect(wAll, hasLength(121));
      expect(wAll.first.timeMs, baseMs + 30 * minMs);
      expect(wAll.last.timeMs, baseMs + 150 * minMs);
    });

    test('falls back to club default when override is null and live-changes X immediately', () {
      final buffer = OwnTrailBuffer();
      for (var m = 0; m <= 30; m++) {
        buffer.add(fixAt(m));
      }

      // Override null -> uses club default (2 min -> m = 28, 29, 30).
      final wClub = buffer.windowedTrail(overrideMinutes: null, clubDefaultMinutes: 2);
      expect(wClub, hasLength(3));

      // Live switch to 15 min -> immediately re-windows (m = 15..30 -> 16 points).
      final w15 = buffer.windowedTrail(overrideMinutes: 15, clubDefaultMinutes: 2);
      expect(w15, hasLength(16));

      // Live switch to Off -> empty trail.
      expect(buffer.windowedTrail(overrideMinutes: 0, clubDefaultMinutes: 2), isEmpty);

      // Live switch back to club default (null -> 2 min).
      expect(buffer.windowedTrail(overrideMinutes: null, clubDefaultMinutes: 2), hasLength(3));
    });

    test('caps ring buffer at maxPoints (2000) and deduplicates identical fixes', () {
      final buffer = OwnTrailBuffer();
      for (var i = 0; i < 2500; i++) {
        buffer.add(
          LocalFix(
            timeMs: baseMs + i * 1000, // 1 Hz for 2500 s (~41 min, inside 120 min)
            latitude: -33.45 + i * 0.00001,
            longitude: -70.55,
          ),
        );
      }
      expect(buffer.length, maxOwnTrailPoints);
      expect(buffer.allFixes.first.timeMs, baseMs + 500 * 1000);
      expect(buffer.latestFix!.timeMs, baseMs + 2499 * 1000);

      // Adding duplicate of latest fix returns false and does not increase length.
      expect(buffer.add(buffer.latestFix!), isFalse);
      expect(buffer.length, maxOwnTrailPoints);

      // Invalid NaN / out-of-range coordinates rejected.
      expect(
        buffer.add(const LocalFix(timeMs: baseMs + 3000000, latitude: double.nan, longitude: -70.5)),
        isFalse,
      );
      expect(
        buffer.add(const LocalFix(timeMs: baseMs + 3000000, latitude: 95.0, longitude: -70.5)),
        isFalse,
      );
    });
  });

  group('buildLiveTrailsLayersParam & buildFadedTrailPolylines', () {
    test('encodes canonical layers query and returns null when both off', () {
      expect(buildLiveTrailsLayersParam(includeClub: true, includePublic: false), 'club');
      expect(buildLiveTrailsLayersParam(includeClub: false, includePublic: true), 'public');
      expect(buildLiveTrailsLayersParam(includeClub: true, includePublic: true), 'club,public');
      expect(buildLiveTrailsLayersParam(includeClub: false, includePublic: false), isNull);
    });

    test('builds fading polylines with distinct own/club/public styles', () {
      final points = [
        for (var i = 0; i < 10; i++) LatLng(-33.45 + i * 0.001, -70.55 + i * 0.001),
      ];
      final times = [for (var i = 0; i < 10; i++) 1_700_000_000_000 + i * 10_000];

      final own = buildFadedTrailPolylines(
        points: points,
        timestampsMs: times,
        kind: MapTrailKind.own,
      );
      final club = buildFadedTrailPolylines(
        points: points,
        timestampsMs: times,
        kind: MapTrailKind.club,
      );
      final pub = buildFadedTrailPolylines(
        points: points,
        timestampsMs: times,
        kind: MapTrailKind.public,
      );

      // Two-pass rendering: halo buckets first, colored core buckets on top.
      // Older segments fade out relative to newest segment.
      final ownCores = own.sublist(own.length ~/ 2);
      final clubCores = club.sublist(club.length ~/ 2);
      final pubCores = pub.sublist(pub.length ~/ 2);
      expect(ownCores.length, greaterThan(1));
      expect(ownCores.first.color.a, lessThan(ownCores.last.color.a));
      expect(clubCores.first.color.a, lessThan(clubCores.last.color.a));
      expect(pubCores.first.color.a, lessThan(pubCores.last.color.a));

      // Distinct visual hierarchy: own thickest with white halo pass underneath,
      // club solid medium, public dashed thinner.
      expect(own.first.strokeWidth, greaterThan(ownCores.last.strokeWidth)); // halo > core
      expect(ownCores.last.strokeWidth, greaterThan(clubCores.last.strokeWidth));
      expect(clubCores.last.strokeWidth, greaterThan(pubCores.last.strokeWidth));
      expect(ownCores.last.pattern, const StrokePattern.solid());
      expect(clubCores.last.pattern, const StrokePattern.solid());
      expect(pubCores.last.pattern.segments, isNotNull);

      // Fewer than 2 points produces no polyline.
      expect(
        buildFadedTrailPolylines(points: [points.first], kind: MapTrailKind.own),
        isEmpty,
      );
    });
  });
}
