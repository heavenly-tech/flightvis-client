import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('FlightVisApiPaths.meLiveTrails and publicLiveTrails match server contract', () {
    expect(FlightVisApiPaths.meLiveTrails, '/api/me/live-trails');
    expect(FlightVisApiPaths.publicLiveTrails, '/api/public/live-trails');
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

      final rClub = await client.fetchLiveTrails(
        includeClub: true,
        includePublic: false,
      );
      final rPub = await client.fetchLiveTrails(
        includeClub: false,
        includePublic: true,
        lat: -33.456,
        lon: -70.548,
        radiusKm: 20,
      );
      final rBoth = await client.fetchLiveTrails(
        includeClub: true,
        includePublic: true,
        lat: -33.456,
        lon: -70.548,
        radiusKm: 50,
      );

      expect(seenRequests, hasLength(3));
      // Club-only URL stays exact with no lat/lon/radius_km.
      expect(
        seenRequests[0].url.toString(),
        'https://example.test/api/me/live-trails?layers=club',
      );
      expect(seenRequests[0].url.queryParameters.containsKey('lat'), isFalse);
      expect(seenRequests[0].url.queryParameters.containsKey('lon'), isFalse);
      expect(seenRequests[0].url.queryParameters.containsKey('radius_km'), isFalse);

      // Public-only sends layers=public + lat + lon + radius_km.
      expect(seenRequests[1].url.path, '/api/me/live-trails');
      expect(seenRequests[1].url.queryParameters, {
        'layers': 'public',
        'lat': '-33.456000',
        'lon': '-70.548000',
        'radius_km': '20',
      });

      // Club + public sends layers=club,public + lat + lon + radius_km.
      expect(seenRequests[2].url.path, '/api/me/live-trails');
      expect(seenRequests[2].url.queryParameters, {
        'layers': 'club,public',
        'lat': '-33.456000',
        'lon': '-70.548000',
        'radius_km': '50',
      });

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

    test('omits lat/lon/radius_km when includePublic is false even if passed', () async {
      final seenRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient((request) async {
          seenRequests.add(request);
          return http.Response(jsonEncode({'flights': []}), 200);
        }),
      );

      await client.fetchLiveTrails(
        includeClub: true,
        includePublic: false,
        lat: -33.456,
        lon: -70.548,
        radiusKm: 20,
      );

      expect(seenRequests, hasLength(1));
      expect(
        seenRequests.single.url.toString(),
        'https://example.test/api/me/live-trails?layers=club',
      );
      expect(seenRequests.single.url.queryParameters.keys, ['layers']);
    });

    test('never requests public layer when coordinates are missing or invalid', () async {
      final seenRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient((request) async {
          seenRequests.add(request);
          return http.Response(jsonEncode({'flights': []}), 200);
        }),
      );

      // Public-only without coords -> zero network calls.
      final resNoCoords = await client.fetchLiveTrails(
        includeClub: false,
        includePublic: true,
        radiusKm: 20,
      );
      expect(resNoCoords.flights, isEmpty);
      expect(seenRequests, isEmpty);

      // Public-only with NaN/out-of-range coords -> zero network calls.
      await client.fetchLiveTrails(
        includeClub: false,
        includePublic: true,
        lat: double.nan,
        lon: -70.548,
        radiusKm: 20,
      );
      await client.fetchLiveTrails(
        includeClub: false,
        includePublic: true,
        lat: 95.0,
        lon: -70.548,
        radiusKm: 20,
      );
      expect(seenRequests, isEmpty);

      // Club + public without coords -> degrades to club-only without position params.
      await client.fetchLiveTrails(
        includeClub: true,
        includePublic: true,
        radiusKm: 20,
      );
      expect(seenRequests, hasLength(1));
      expect(
        seenRequests.single.url.toString(),
        'https://example.test/api/me/live-trails?layers=club',
      );
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

    test('throws FlightVisException on non-200/304 responses (401 and 400)', () async {
      final client401 = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'unauthorized'}), 401),
        ),
      );

      await expectLater(
        () => client401.fetchLiveTrails(includeClub: true, includePublic: false),
        throwsA(
          isA<FlightVisException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );

      final client400 = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: 'tok-1',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'bad_request'}), 400),
        ),
      );

      await expectLater(
        () => client400.fetchLiveTrails(
          includeClub: false,
          includePublic: true,
          lat: -33.456,
          lon: -70.548,
          radiusKm: 20,
        ),
        throwsA(
          isA<FlightVisException>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });
  });

  group('fetchPublicLiveTrails (anonymous endpoint)', () {
    test('sends lat/lon/radius_km and Accept-Language with ZERO auth headers', () async {
      final seenRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'secret-sess-must-not-be-sent',
        deviceToken: 'secret-tok-must-not-be-sent',
        httpClient: MockClient((request) async {
          seenRequests.add(request);
          if (request.headers['If-None-Match'] == 'W/"pub-1"') {
            return http.Response('', 304, headers: {'etag': 'W/"pub-1"'});
          }
          return http.Response(
            jsonEncode({
              'flights': [
                {
                  'flightId': 'flt_pub',
                  'tail': 'CC-PUB',
                  'layer': 'public',
                  'trailMinutes': 5,
                  'points': [
                    [1700000000000, -33.456, -70.548, 950.0],
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
            headers: {'etag': 'W/"pub-1"'},
          );
        }),
      )..setAcceptLanguage('es-CL');

      final res = await client.fetchPublicLiveTrails(
        lat: -33.4567891,
        lon: -70.5481234,
        radiusKm: 20,
      );

      expect(seenRequests, hasLength(1));
      final req = seenRequests.single;
      expect(req.method, 'GET');
      expect(req.url.path, '/api/public/live-trails');
      expect(req.url.queryParameters, {
        'lat': '-33.456789',
        'lon': '-70.548123',
        'radius_km': '20',
      });
      expect(req.headers['Accept-Language'], 'es-CL');
      expect(req.headers.containsKey('Cookie'), isFalse);
      expect(req.headers.containsKey('Authorization'), isFalse);
      expect(res.flights, hasLength(1));
      expect(res.flights.single.tail, 'CC-PUB');
      expect(res.etag, 'W/"pub-1"');

      // 304 with If-None-Match
      final res304 = await client.fetchPublicLiveTrails(
        lat: -33.4567891,
        lon: -70.5481234,
        radiusKm: 20,
        ifNoneMatch: 'W/"pub-1"',
      );
      expect(res304.notModified, isTrue);
      expect(seenRequests.last.headers['If-None-Match'], 'W/"pub-1"');
      expect(seenRequests.last.headers.containsKey('Cookie'), isFalse);
      expect(seenRequests.last.headers.containsKey('Authorization'), isFalse);
    });

    test('clamps radius_km to 5..500 and skips request on invalid coords', () async {
      final seenRequests = <http.Request>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: MockClient((request) async {
          seenRequests.add(request);
          return http.Response(jsonEncode({'flights': []}), 200);
        }),
      );

      final invalid = await client.fetchPublicLiveTrails(
        lat: double.nan,
        lon: -70.5,
        radiusKm: 20,
      );
      expect(invalid.flights, isEmpty);
      expect(seenRequests, isEmpty);

      await client.fetchPublicLiveTrails(lat: -33.4, lon: -70.5, radiusKm: 1);
      await client.fetchPublicLiveTrails(lat: -33.4, lon: -70.5, radiusKm: 999);
      expect(seenRequests[0].url.queryParameters['radius_km'], '5');
      expect(seenRequests[1].url.queryParameters['radius_km'], '500');
    });
  });
}
