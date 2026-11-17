import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  test('endFlight treats 409 as success and clears server-ended flights (C-3)', () async {
    var calls = 0;
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        calls++;
        expect(request.url.path, '/api/flights/f1/end');
        return http.Response(jsonEncode({'error': 'not active'}), 409);
      }),
    );
    await client.endFlight('f1');
    expect(calls, 1);
  });

  test('isFlightActiveOnServer reads /api/me/flights', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      sessionId: 'sess',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/me/flights');
        return http.Response(
          jsonEncode({
            'flights': [
              {'id': 'f1', 'tail': 'N1', 'status': 'ended'},
              {'id': 'f2', 'tail': 'N2', 'status': 'active'},
            ],
          }),
          200,
        );
      }),
    );
    expect(await client.isFlightActiveOnServer('f2'), isTrue);
    expect(await client.isFlightActiveOnServer('f1'), isFalse);
  });
}