import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('FlightVisApiPaths.meLiveTrails matches server contract', () {
    expect(FlightVisApiPaths.meLiveTrails, '/api/me/live-trails');
  });

  group('fetchLiveTrails', () {
    test('skips network request completely when both club and public are off', () async {
      var calls = 0;
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        deviceToken: 'dev-tok',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      final res = await client.fetchLiveTrails(
        includeClub: false,
        includePublic: false,
      );
      expect(calls, 0);
      expect(res.flights, isEmpty);
      expect(res.notModified, isFalse);
    });

    test('sends exact layers query, auth headers, and parses flights + caps', () async {
      final seenRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-live',
        deviceToken: 'tok-live',
        httpClient: MockClient((request) async {
          seenRequests.add(request);
          return http.Response(
            jsonEncode({
              'flights': [
                {
                  'flightId': 'flt_1',
                  'tail': 'CC-CLB',
                  'layer': 'club',
                  'trailMinutes': 5,
                  'points': [
                    [1700000000000, -33.456, -70.548, 920.5],
                    [1700000060000, -33.452, -70.544, null],
                  ],
                },
                {
                  'flightId': 'flt_2',
                  'tail': 'CC-OFF',
                  'layer': 'public',
                  'trailMinutes': 0,
                  'points': [
                    [1700000060000, -33.460, -70.555, null],
                  ],
                },
              ],
              'caps': {
                'maxFlights': 50,
                'maxPointsPerFlight': 300,
                'maxWindowMinutes': 120,
              },
            }),
            200,
            headers: {'etag': 'W/"abc123"'},
          );
        }),
      )..setAcceptLanguage('es-CL');

      final rClub = await client.fetchLiveTrails(includeClub: true, includePublic: false);
      final rPub = await client.fetchLiveTrails(includeClub: false, includePublic: true);
      final rBoth = await client.fetchLiveTrails(includeClub: true, includePublic: true);

      expect(seenRequests.map((r) => r.url.toString()).toList(), [
        'https://example.test/api/me/live-trails?layers=club',
        'https://example.test/api/me/live-trails?layers=public',
        'https://example.test/api/me/live-trails?layers=club%2Cpublic',
      ]);

      final req = seenRequests.first;
      expect(req.method, 'GET');
      expect(req.headers['Cookie'], 'fv_club_session=sess-live');
      expect(req.headers['Authorization'], 'Bearer tok-live');
      expect(req.headers['Accept-Language'], 'es-CL');

      expect(rClub.etag, 'W/"abc123"');
      expect(rClub.notModified, isFalse);
      expect(rClub.flights, hasLength(2));
      expect(rClub.flights[0].flightId, 'flt_1');
      expect(rClub.flights[0].tail, 'CC-CLB');
      expect(rClub.flights[0].isClub, isTrue);
      expect(rClub.flights[0].points, hasLength(2));
      expect(rClub.flights[0].points[0].altitude, 920.5);
      expect(rClub.flights[0].points[1].altitude, isNull);
      expect(rClub.flights[1].isPublic, isTrue);
      expect(rClub.flights[1].trailMinutes, 0);
      expect(rClub.flights[1].points, hasLength(1));
      expect(rClub.caps?.maxFlights, 50);
      expect(rClub.caps?.maxPointsPerFlight, 300);
      expect(rClub.caps?.maxWindowMinutes, 120);
      expect(rPub.flights, hasLength(2));
      expect(rBoth.flights, hasLength(2));
    });

    test('sends If-None-Match and handles 304 Not Modified', () async {
      String? capturedIfNoneMatch;
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient((request) async {
          capturedIfNoneMatch = request.headers['If-None-Match'];
          return http.Response('', 304, headers: {'etag': 'W/"same-tag"'});
        }),
      );

      final res = await client.fetchLiveTrails(
        includeClub: true,
        includePublic: false,
        ifNoneMatch: 'W/"same-tag"',
      );

      expect(capturedIfNoneMatch, 'W/"same-tag"');
      expect(res.notModified, isTrue);
      expect(res.etag, 'W/"same-tag"');
      expect(res.flights, isEmpty);
    });

    test('throws FlightVisException on non-200/304 responses', () async {
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'unauthorized'}), 401),
        ),
      );

      await expectLater(
        () => client.fetchLiveTrails(includeClub: true, includePublic: false),
        throwsA(
          isA<FlightVisException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });
}
