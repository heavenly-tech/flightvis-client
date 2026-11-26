import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('FlightVisApiPaths.flightTrail builds expected path', () {
    expect(FlightVisApiPaths.flightTrail('f1'), '/api/flights/f1/trail');
  });

  group('startFlight trailMinutes', () {
    test('omits trailMinutes by default and when club default (null) is chosen', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, FlightVisApiPaths.flights);
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'id': 'f1',
              'visibility': 'club',
              'showPilotNamePublic': false,
              'trailMinutes': null,
            }),
            200,
          );
        }),
      );

      final r1 = await client.startFlight(tail: 'CC-ABC');
      final r2 = await client.startFlight(
        tail: 'CC-ABC',
        trailMinutes: null,
        sendTrail: true,
      );
      final r3 = await client.startFlight(
        tail: 'CC-ABC',
        trailMinutes: 10,
        sendTrail: false,
      );

      for (final body in bodies) {
        expect(body.containsKey('trailMinutes'), isFalse);
      }
      expect(r1.trailMinutes, isNull);
      expect(r1.hasTrailMinutes, isTrue);
      expect(r2.trailMinutes, isNull);
      expect(r3.trailMinutes, isNull);
    });

    test('includes trailMinutes when explicitly chosen (0, 10, -1) and parses response', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient((request) async {
          final decoded = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(decoded);
          return http.Response(
            jsonEncode({
              'id': 'f1',
              'visibility': 'club',
              'showPilotNamePublic': false,
              'trailMinutes': decoded['trailMinutes'],
            }),
            200,
          );
        }),
      );

      for (final value in [0, 2, 5, 10, 15, 30, -1]) {
        final result = await client.startFlight(
          tail: 'CC-ABC',
          trailMinutes: value,
          sendTrail: true,
        );
        expect(result.trailMinutes, value);
        expect(result.hasTrailMinutes, isTrue);
      }

      expect(bodies.map((b) => b['trailMinutes']).toList(), [0, 2, 5, 10, 15, 30, -1]);
    });
  });

  group('setFlightTrail', () {
    test('sends PATCH to /api/flights/f1/trail with body and same auth headers as endFlight', () async {
      final capturedRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-123',
        deviceToken: 'dev-tok-456',
        httpClient: MockClient((request) async {
          capturedRequests.add(request);
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({'trailMinutes': body['trailMinutes']}),
              200,
            );
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      )..setAcceptLanguage('es-CL');

      final updated = await client.setFlightTrail('f1', 15);
      final cleared = await client.setFlightTrail('f1', null);
      await client.endFlight('f1');

      expect(updated, 15);
      expect(cleared, isNull);
      expect(capturedRequests, hasLength(3));

      final patchSet = capturedRequests[0];
      final patchReset = capturedRequests[1];
      final endReq = capturedRequests[2];

      expect(patchSet.method, 'PATCH');
      expect(patchSet.url.path, '/api/flights/f1/trail');
      expect(jsonDecode(patchSet.body), {'trailMinutes': 15});
      expect(patchSet.headers['Content-Type'], startsWith('application/json'));
      expect(patchSet.headers['Cookie'], endReq.headers['Cookie']);
      expect(patchSet.headers['Authorization'], endReq.headers['Authorization']);
      expect(patchSet.headers['Accept-Language'], endReq.headers['Accept-Language']);
      expect(patchSet.headers['Cookie'], 'fv_club_session=sess-123');
      expect(patchSet.headers['Authorization'], 'Bearer dev-tok-456');

      expect(patchReset.method, 'PATCH');
      expect(patchReset.url.path, '/api/flights/f1/trail');
      final resetBody = jsonDecode(patchReset.body) as Map<String, dynamic>;
      expect(resetBody.containsKey('trailMinutes'), isTrue);
      expect(resetBody['trailMinutes'], isNull);
    });

    test('treats 409 flight already ended as a no-op', () async {
      var calls = 0;
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'dev-tok',
        httpClient: MockClient((request) async {
          calls++;
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/flights/f1/trail');
          return http.Response(jsonEncode({'error': 'not active'}), 409);
        }),
      );

      final result = await client.setFlightTrail('f1', 5);
      expect(calls, 1);
      expect(result, 5);
    });

    test('throws FlightVisException on 400, 403, and 404', () async {
      for (final status in [400, 403, 404]) {
        final client = FlightVisClient(
          baseUrl: 'https://example.test',
          deviceToken: 'dev-tok',
          httpClient: MockClient((_) async {
            return http.Response(jsonEncode({'error': 'err_$status'}), status);
          }),
        );

        await expectLater(
          () => client.setFlightTrail('f1', 10),
          throwsA(
            isA<FlightVisException>().having((e) => e.statusCode, 'statusCode', status),
          ),
        );
      }
    });
  });

  group('meProfile clubTrailMinutesDefault', () {
    test('reads clubTrailMinutesDefault from GET /api/club/me and clears on logout', () async {
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(
              jsonEncode({
                'clubTrailMinutesDefault': 5,
                'pilot': {
                  'id': 'p1',
                  'name': 'Ada',
                  'email': 'ada@test',
                  'status': 'approved',
                  'role': 'pilot',
                },
              }),
              200,
            );
          }
          if (request.method == 'POST' && request.url.path == FlightVisApiPaths.clubLogout) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 404);
        }),
      );

      final profile = await client.meProfile();
      expect(profile?.clubTrailMinutesDefault, 5);
      expect(client.clubTrailMinutesDefault, 5);

      await client.logout();
      expect(client.clubTrailMinutesDefault, isNull);
    });

    test('supports 0 and -1 clubTrailMinutesDefault and null when omitted', () async {
      for (final raw in <dynamic>[0, -1, null]) {
        final client = FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'sess-1',
          httpClient: MockClient((_) async {
            return http.Response(
              jsonEncode({
                if (raw != null) 'clubTrailMinutesDefault': raw,
                'pilot': {
                  'id': 'p1',
                  'name': 'Ada',
                  'email': 'ada@test',
                  'status': 'approved',
                  'role': 'pilot',
                },
              }),
              200,
            );
          }),
        );

        final profile = await client.meProfile();
        expect(profile?.clubTrailMinutesDefault, raw);
        expect(client.clubTrailMinutesDefault, raw);
      }
    });
  });
}
