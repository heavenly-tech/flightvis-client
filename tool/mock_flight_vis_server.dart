import 'dart:convert';
import 'dart:io';

/// Minimal club API mock for emulator integration screenshots (CI).
Future<void> main() async {
  const session = 'ci-mock-session';
  const clubSlug = 'demo-club';
  const clubName = 'Club Demo';
  int? checkinExpiresAtMs;
  String? activeFlightId;
  const deviceToken =
      'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';

  final server = await HttpServer.bind(InternetAddress.anyIPv4, int.parse(
    Platform.environment['MOCK_PORT'] ?? '18080',
  ));
  // ignore: avoid_print
  print('mock flight_vis listening on ${server.port}');

  bool checkinValid() {
    final expires = checkinExpiresAtMs;
    if (expires == null) return false;
    return DateTime.now().millisecondsSinceEpoch < expires;
  }

  bool isClubScoped(String path, String tail) => path == '/api/clubs/$clubSlug/$tail';

  await for (final request in server) {
    final path = request.uri.path;
    final method = request.method;
    Future<void> jsonResponse(int code, Map<String, dynamic> body, {String? cookie}) async {
      request.response.statusCode = code;
      request.response.headers.contentType = ContentType.json;
      if (cookie != null) {
        request.response.headers.set('set-cookie', 'fv_club_session=$cookie; Path=/');
      }
      request.response.write(jsonEncode(body));
      await request.response.close();
    }

    if (method == 'POST' && path == '/api/devices/anonymous') {
      await jsonResponse(200, {
        'id': 'dev-ci',
        'token': deviceToken,
      });
      continue;
    }

    if (method == 'POST' && (path == '/api/me/devices' || isClubScoped(path, 'me/devices'))) {
      await jsonResponse(200, {
        'id': 'dev-ci',
        'token': deviceToken,
        'label': 'Android',
      });
      continue;
    }

    if (method == 'GET' && path == '/api/clubs/$clubSlug') {
      await jsonResponse(200, {'slug': clubSlug, 'name': clubName});
      continue;
    }

    if (method == 'POST' && path == '/api/auth/magic/send') {
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/auth/magic/complete') {
      await jsonResponse(200, {
        'ok': true,
        'pilot': {
          'id': 'p1',
          'name': 'Demo Pilot',
          'email': 'pilot@demo.test',
          'status': 'approved',
          'role': 'pilot',
        },
      }, cookie: session);
      continue;
    }

    if (method == 'POST' && path == '/api/auth/passkey/login/options') {
      await jsonResponse(200, {
        'challenge': 'dGVzdA',
        'timeout': 60000,
        'rpId': 'flight.heavenly.cl',
        'userVerification': 'preferred',
      });
      continue;
    }

    if (method == 'POST' && path == '/api/auth/passkey/login/verify') {
      await jsonResponse(200, {
        'pilot': {
          'id': 'p1',
          'name': 'Demo Pilot',
          'email': 'pilot@demo.test',
          'status': 'approved',
          'role': 'pilot',
        },
      }, cookie: session);
      continue;
    }

    if (method == 'POST' && path == '/api/club/login') {
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if (body['email'] == 'pilot@demo.test' && body['password'] == 'password12') {
        await jsonResponse(200, {
          'ok': true,
          'pilot': {
            'id': 'p1',
            'name': 'Demo Pilot',
            'email': 'pilot@demo.test',
            'status': 'approved',
            'role': 'pilot',
          },
        }, cookie: session);
        continue;
      }
      await jsonResponse(401, {'error': 'unauthorized'});
      continue;
    }

    if (method == 'GET' && path == '/api/club/me') {
      final cookie = request.headers.value('cookie') ?? '';
      if (cookie.contains(session)) {
        await jsonResponse(200, {
          'pilot': {
            'id': 'p1',
            'name': 'Demo Pilot',
            'email': 'pilot@demo.test',
            'status': 'approved',
            'role': 'pilot',
            'licenseNo': 'L-1',
          },
        });
      } else {
        await jsonResponse(200, {'pilot': null});
      }
      continue;
    }

    if (method == 'POST' && (path == '/api/checkin' || isClubScoped(path, 'checkin'))) {
      final expires = DateTime.now().toUtc().add(const Duration(hours: 12));
      checkinExpiresAtMs = expires.millisecondsSinceEpoch;
      await jsonResponse(200, {
        'ok': true,
        'expiresAt': expires.toIso8601String(),
        'club': {'slug': clubSlug, 'name': clubName},
      });
      continue;
    }

  if (method == 'GET' && (path == '/api/me/tails' || isClubScoped(path, 'me/tails'))) {
      await jsonResponse(200, {
        'tails': [
          {'id': 'a1', 'tail': 'N12345', 'type_code': 'C172'},
        ],
      });
      continue;
    }

    if (method == 'POST' && (path == '/api/flights' || isClubScoped(path, 'flights'))) {
      if (!checkinValid()) {
        await jsonResponse(403, {'error': 'check-in required'});
        continue;
      }
      if (activeFlightId != null) {
        await jsonResponse(409, {'error': 'flight already active'});
        continue;
      }
      activeFlightId = 'flight-ci-1';
      await jsonResponse(200, {
        'id': activeFlightId,
        'visibility': 'club',
        'showPilotNamePublic': false,
      });
      continue;
    }

    final endMatch = RegExp(r'^/api/(clubs/[^/]+/)?flights/([^/]+)/end$').firstMatch(path);
    if (method == 'POST' && endMatch != null) {
      activeFlightId = null;
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/club/logout') {
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/osmand') {
      await jsonResponse(200, {'ok': true});
      continue;
    }

    request.response.statusCode = 404;
    request.response.write('not found: $path');
    await request.response.close();
  }
}