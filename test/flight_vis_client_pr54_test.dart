import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('setFlightTrail treats 404 like ended flight (PR #54)', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      sessionId: 'sess',
      deviceToken: 'tok-01234567890123456789012345678901',
      httpClient: MockClient((request) async {
        expect(request.method, 'PATCH');
        expect(request.url.path, endsWith(FlightVisApiPaths.flightTrail('f1')));
        return http.Response(jsonEncode({'error': 'not found'}), 404);
      }),
    );
    final out = await client.setFlightTrail('f1', 5);
    expect(out, 5);
  });

  test('LiveTrailFlight parses otherClub (PR #54 L-92)', () {
    final flight = LiveTrailFlight.fromJson(<String, dynamic>{
      'flightId': 'x',
      'tail': 'CC-X',
      'layer': 'public',
      'trailMinutes': 5,
      'otherClub': true,
      'points': [
        [1_700_000_000_000, -33.0, -70.0, 100.0],
      ],
    });
    expect(flight.otherClub, isTrue);
    expect(flight.isDistinctNonOwnClub, isTrue);
  });

  test('FlightVisException maps 404 flight ownership like 403', () {
    final e = FlightVisException(
      'not found',
      statusCode: 404,
      body: <String, dynamic>{'error': 'not found'},
    );
    expect(e.isFlightNotYoursOrMissing, isTrue);
  });
}