import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('login stores session and returns pilot', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/club/login') {
          expect(request.url.path, '/api/club/login');
          return http.Response(
            jsonEncode({
              'ok': true,
              'pilot': {
                'id': 'p1',
                'name': 'Ada',
                'email': 'a@test',
                'status': 'approved',
                'role': 'pilot',
              },
            }),
            200,
            headers: {
              'set-cookie': 'fv_club_session=abc123; Path=/; HttpOnly',
            },
          );
        }
        return http.Response(jsonEncode({'pilot': null}), 200);
      }),
    );
    final pilot = await client.login('a@test', 'secret');
    expect(pilot.name, 'Ada');
    expect(client.sessionId, 'abc123');
  });

  test('checkin posts token with bearer', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      deviceToken: 'd'.padRight(48, 'x'),
      httpClient: MockClient((request) async {
        expect(request.headers['Authorization'], startsWith('Bearer '));
        expect(jsonDecode(request.body), {'token': 'qr-token'});
        return http.Response(
          jsonEncode({
            'ok': true,
            'expiresAt': '2026-11-17T15:00:00Z',
          }),
          200,
        );
      }),
    );
    final result = await client.checkin('qr-token');
    expect(result.expiresAtUtc, isNotNull);
  });

  test('startFlight surfaces server error', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        return http.Response(jsonEncode({'error': 'check-in required'}), 403);
      }),
    );
    expect(
      () => client.startFlight(tail: 'N1'),
      throwsA(isA<FlightVisException>()),
    );
  });
}