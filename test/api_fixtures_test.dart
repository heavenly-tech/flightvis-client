import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_client.dart';

late Map<String, dynamic> fixtures;

void main() {
  setUpAll(() {
    final raw = File('test/fixtures/flight_vis_pr15_api.json').readAsStringSync();
    fixtures = jsonDecode(raw) as Map<String, dynamic>;
  });

  test('parses PR #15 fixture responses', () {
    PilotProfile.fromJson(
      (fixtures['post_club_login_success'] as Map)['pilot'] as Map<String, dynamic>,
    );
    PilotProfile.fromJson(
      (fixtures['get_club_me_success'] as Map)['pilot'] as Map<String, dynamic>,
    );
    final checkin = CheckinResult.fromJson(
      fixtures['post_checkin_success'] as Map<String, dynamic>,
    );
    expect(checkin.ok, isTrue);
    expect(checkin.expiresAtUtc?.isUtc, isTrue);
    TailOption.fromJson(
      ((fixtures['get_me_tails_success'] as Map)['tails'] as List).first
          as Map<String, dynamic>,
    );
    StartFlightResult.fromJson(
      fixtures['post_flights_success'] as Map<String, dynamic>,
    );
  });

  test('checkin expiresAt maps to epoch ms', () {
    final checkin = CheckinResult.fromJson(
      fixtures['post_checkin_success'] as Map<String, dynamic>,
    );
    expect(checkin.expiresAtEpochMs(), DateTime.parse('2026-11-17T15:00:00Z').millisecondsSinceEpoch);
  });

  test('checkin without expiresAt falls back to 30 minutes', () {
    final checkin = CheckinResult.fromJson({'ok': true});
    final now = 1_700_000_000_000;
    expect(
      checkin.expiresAtEpochMs(nowMs: now),
      now + 30 * 60 * 1000,
    );
  });

  test('startFlight encodes PR #15 request body', () async {
  String? capturedBody;
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      deviceToken: 'x'.padRight(48, 'x'),
      httpClient: MockClient((request) async {
        capturedBody = request.body;
        return http.Response(
          jsonEncode(fixtures['post_flights_success']),
          200,
        );
      }),
    );
    await client.startFlight(tail: 'N12345');
    expect(
      jsonDecode(capturedBody!),
      fixtures['post_flights_request'],
    );
  });

  test('access request encode and parse', () async {
    String? captured;
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        captured = request.body;
        return http.Response(jsonEncode(fixtures['post_access_requests_success']), 200);
      }),
    );
    final req = await client.createAccessRequest(tail: 'CC-ABC', typeCode: 'C172');
    expect(jsonDecode(captured!), fixtures['post_access_requests_request']);
    expect(req.status, 'pending');
    AccessRequest.fromJson(
      ((fixtures['get_access_requests_rejected'] as Map)['requests'] as List).first
          as Map<String, dynamic>,
    );
  });

  test('login calls /me after session cookie', () async {
    final paths = <String>[];
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/club/login') {
          return http.Response(
            jsonEncode(fixtures['post_club_login_success']),
            200,
            headers: {'set-cookie': 'fv_club_session=sess; Path=/'},
          );
        }
        if (request.url.path == '/api/club/me') {
          return http.Response(
            jsonEncode(fixtures['get_club_me_success']),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final pilot = await client.login('pilot@demo.test', 'password12');
    expect(paths, ['/api/club/login', '/api/club/me']);
    expect(pilot.licenseNo, 'L-1');
  });
}