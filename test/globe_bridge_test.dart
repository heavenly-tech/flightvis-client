import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/map/globe_bridge.dart';
import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/services/native_fix_queue.dart';

void main() {
  group('buildGlobeEmbedUri', () {
    test('builds exact /embed/3d?ui=mobile&v=1 on https base', () {
      final uri = buildGlobeEmbedUri('https://flight.heavenly.cl');
      expect(uri, isNotNull);
      expect(uri.toString(), 'https://flight.heavenly.cl/embed/3d?ui=mobile&v=1');
    });
  });

  group('decideGlobeNavigation', () {
    final embed = Uri.parse('https://flight.heavenly.cl/embed/3d?ui=mobile&v=1');

    test('allows exact embed URL only', () {
      expect(
        decideGlobeNavigation(embed, embed, isMainFrame: true),
        GlobeNavigationAction.allow,
      );
    });

    test('blocks other paths on same host', () {
      final other = Uri.parse('https://flight.heavenly.cl/api/me');
      expect(
        decideGlobeNavigation(other, embed, isMainFrame: true),
        GlobeNavigationAction.prevent,
      );
    });

    test('opens external https credit links in browser', () {
      final credits = Uri.parse('https://cesium.com/attribution');
      expect(
        decideGlobeNavigation(credits, embed, isMainFrame: true),
        GlobeNavigationAction.preventAndOpenExternal,
      );
    });
  });

  group('GlobeBridgeEncoder', () {
    test('wraps payloads without session secrets', () {
      const session = 'super-session-token-abc';
      const device = '01234567890123456789012345678901';
      final js = GlobeBridgeEncoder.toReceiveJavaScript(<String, dynamic>{
        'type': 'init',
        'protocol': 1,
        'lang': 'es',
        'ownFlightId': 'flt-1',
      });
      expect(js, contains('window.fvBridge.receive'));
      expect(js, isNot(contains(session)));
      expect(js, isNot(contains(device)));
    });

    test('init + flights shapes respect caps and altitude meters', () {
      final flights = buildGlobeBridgeFlights(
        showOwn: true,
        ownFlightId: 'own-1',
        ownTail: 'CC-OWN',
        ownTrailPoints: [
          LocalFix(
            timeMs: 1_700_000_000_000,
            latitude: -33.45,
            longitude: -70.66,
            altitude: 1200.5,
          ),
        ],
        remoteFlights: [
          LiveTrailFlight(
            flightId: 'remote-1',
            tail: 'CC-R1',
            layer: 'public',
            trailMinutes: 5,
            otherClub: true,
            points: const [
              LiveTrailPoint(
                timeMs: 1_700_000_100_000,
                latitude: -33.44,
                longitude: -70.65,
                altitude: 900,
              ),
            ],
          ),
        ],
      );
      expect(flights, hasLength(2));
      expect(flights.last.otherClub, isTrue);
      final payload = GlobeBridgeEncoder.flights(mode: 'full', flights: flights);
      final remote = (payload['flights'] as List).last as Map<String, dynamic>;
      expect(remote['otherClub'], true);
      final point = (remote['points'] as List).single as List;
      expect(point[3], 900);
    });
  });

  group('GlobeFlightSyncTracker', () {
    test('emits full then delta on append', () {
      final tracker = GlobeFlightSyncTracker();
      final initial = [
        GlobeBridgeFlight(
          id: 'f1',
          tail: 'CC-A',
          tailSource: 'club',
          layer: 'own',
          points: [
            GlobeBridgePoint(
              timeMs: 1,
              latitude: 0,
              longitude: 0,
              altitudeMeters: 10,
            ),
          ],
        ),
      ];
      final full = tracker.buildNextMessage(initial);
      expect(full?['mode'], 'full');
      final updated = [
        GlobeBridgeFlight(
          id: 'f1',
          tail: 'CC-A',
          tailSource: 'club',
          layer: 'own',
          points: [
            ...initial.single.points,
            GlobeBridgePoint(
              timeMs: 2,
              latitude: 0.1,
              longitude: 0.1,
              altitudeMeters: 11,
            ),
          ],
        ),
      ];
      final delta = tracker.buildNextMessage(updated);
      expect(delta?['mode'], 'delta');
    });
  });

  group('parseGlobeInboundMessage', () {
    test('ignores unknown inbound types', () {
      expect(parseGlobeInboundMessage(jsonEncode({'type': 'unknown'})), isNull);
    });
  });

  group('L-94 isFixAtOrAfterFlightStart', () {
    test('drops strict pre-start fixes with zero tolerance', () {
      expect(
        isFixAtOrAfterFlightStart(tMs: 999, startedAtMs: 1000),
        isFalse,
      );
      expect(
        isFixAtOrAfterFlightStart(tMs: 1000, startedAtMs: 1000),
        isTrue,
      );
    });
  });
}