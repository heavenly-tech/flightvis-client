import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/l10n/api_errors.dart';
import 'package:flight_vis/l10n/app_localizations_en.dart';
import 'package:flight_vis/l10n/app_localizations_es.dart';

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

  test('startFlight shows not-cleared message from server', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'not cleared for CC-ABC / C172'}),
          403,
        );
      }),
    );
    try {
      await client.startFlight(tail: 'CC-ABC');
      fail('expected exception');
    } on FlightVisException catch (e) {
      expect(e.message, 'not cleared for CC-ABC / C172');
      expect(e.statusCode, 403);
    }
  });

  group('GET /api/club/me top-level email_verified parsing', () {
    test('parses top-level email_verified true, false, and missing -> false', () async {
      final basePilot = {
        'id': 'p1',
        'name': 'Ada',
        'email': 'ada@club.cl',
        'status': 'approved',
        'role': 'pilot',
      };

      Future<PilotProfile?> fetchWithBody(Map<String, dynamic> body) async {
        final client = FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'sess-1',
          httpClient: MockClient((_) async => http.Response(jsonEncode(body), 200)),
        );
        return client.meProfile();
      }

      final verified = await fetchWithBody({
        'pilot': basePilot,
        'email_verified': true,
      });
      expect(verified?.emailVerified, isTrue);

      final unverified = await fetchWithBody({
        'pilot': basePilot,
        'email_verified': false,
      });
      expect(unverified?.emailVerified, isFalse);

      // Missing top-level email_verified defaults to false even for approved pilots
      // and even if a legacy nested field appeared inside pilot.
      final missing = await fetchWithBody({
        'pilot': {...basePilot, 'emailVerified': true, 'email_verified': true},
      });
      expect(missing?.emailVerified, isFalse);

      // Cached JSON round-trip preserves emailVerified.
      final roundTripped = PilotProfile.fromJson(verified!.toJson());
      expect(roundTripped.emailVerified, isTrue);
      final roundTrippedFalse = PilotProfile.fromJson(unverified!.toJson());
      expect(roundTrippedFalse.emailVerified, isFalse);
    });
  });

  group('403 email_not_verified error localization', () {
    final es = AppLocalizationsEs();
    final en = AppLocalizationsEn();

    test('POST /api/flights 403 email_not_verified localizes in es-CL and en', () async {
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/flights');
          return http.Response(
            jsonEncode({
              'error': 'email_not_verified',
              'message': 'Verify your email to share flights publicly.',
            }),
            403,
          );
        }),
      );

      try {
        await client.startFlight(tail: 'CC-ABC', visibility: 'public');
        fail('expected FlightVisException');
      } on FlightVisException catch (e) {
        expect(e.statusCode, 403);
        expect(
          localizeApiException(es, e),
          'Verifica tu correo para compartir vuelos en público.',
        );
        expect(
          localizeApiException(en, e),
          'Verify your email to share flights publicly.',
        );
      }
    });

    test('PATCH /api/flights/{slug} 403 email_not_verified localizes in es-CL and en', () async {
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        httpClient: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/flights/my-flight-slug');
          expect(jsonDecode(request.body), {'visibility': 'public'});
          return http.Response(
            jsonEncode({
              'error': 'email_not_verified',
              'message': 'Verify your email to share flights publicly.',
            }),
            403,
          );
        }),
      );

      try {
        await client.updateFlightVisibility(
          'my-flight-slug',
          visibility: 'public',
        );
        fail('expected FlightVisException');
      } on FlightVisException catch (e) {
        expect(e.statusCode, 403);
        expect(
          localizeApiException(es, e),
          'Verifica tu correo para compartir vuelos en público.',
        );
        expect(
          localizeApiException(en, e),
          'Verify your email to share flights publicly.',
        );
      }
    });
  });
}