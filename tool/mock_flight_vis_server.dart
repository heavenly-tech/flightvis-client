import 'dart:convert';
import 'dart:io';

/// Minimal club API mock for emulator integration screenshots (CI).
Future<void> main() async {
  const session = 'ci-mock-session';
  const clubSlug = 'demo-club';
  const clubName = 'Club Demo';
  int? checkinExpiresAtMs;
  String? activeFlightId;
  int? activeFlightTrailMinutes;
  const clubTrailMinutesDefault = 5;
  const allowedTrailMinutes = {-1, 0, 2, 5, 10, 15, 30};
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

    if (method == 'GET' && path == '/api/ci-health') {
      await jsonResponse(200, {'ok': true, 'source': 'mock_flight_vis_server'});
      continue;
    }

    if (method == 'POST' && path == '/api/devices/anonymous') {
      await jsonResponse(200, {
        'ok': true,
        'pilot': {
          'id': 'guest-1',
          'name': 'Guest',
          'email': 'guest-1@guest.invalid',
          'status': 'approved',
          'role': 'pilot',
        },
      }, cookie: session);
      continue;
    }

    if (method == 'POST' && path == '/api/me/devices') {
      final cookie = request.headers.value('cookie') ?? '';
      if (!cookie.contains(session)) {
        await jsonResponse(200, {'ok': true, 'ignored': true});
        continue;
      }
      await jsonResponse(200, {
        'id': 'dev-ci',
        'token': deviceToken,
        'label': 'Android',
        'created': true,
      });
      continue;
    }

    if (method == 'GET' && path == '/api/clubs/$clubSlug') {
      await jsonResponse(200, {
        'club': {
          'id': 'club-ci',
          'slug': clubSlug,
          'name': clubName,
          'defaultLocale': 'es',
        },
        'userLocale': null,
      });
      continue;
    }

    if (method == 'POST' && path == '/api/auth/magic/send') {
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/auth/magic/complete') {
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if ((body['token'] as String?)?.isEmpty ?? true) {
        await jsonResponse(400, {'error': 'invalid'});
        continue;
      }
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
        'nonce': 'ci-nonce',
        'publicKey': {
          'challenge': 'dGVzdA',
          'timeout': 60000,
          'rpId': 'flight.heavenly.cl',
          'userVerification': 'preferred',
        },
      });
      continue;
    }

    if (method == 'POST' && path == '/api/auth/passkey/login/verify') {
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
          'clubTrailMinutesDefault': clubTrailMinutesDefault,
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

    if (method == 'POST' && path == '/api/checkin') {
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final token = (body['token'] as String? ?? '').trim();
      final auth = request.headers.value('authorization') ?? '';
      final cookie = request.headers.value('cookie') ?? '';
      final hasBearer = auth.startsWith('Bearer ') && auth.length > 'Bearer '.length;
      final hasSession = cookie.contains(session);
      if (!hasBearer && !hasSession) {
        await jsonResponse(401, {
          'error': 'no_device',
          'reason': 'no_device',
          'message': 'No encontramos tu sesión. Inicia sesión o escanea el QR de nuevo.',
        });
        continue;
      }
      if (token.isEmpty) {
        await jsonResponse(400, {
          'error': 'format',
          'reason': 'format',
          'message': 'El código no es válido. Escanea el QR de nuevo.',
        });
        continue;
      }
      final expires = DateTime.now().toUtc().add(const Duration(hours: 12));
      checkinExpiresAtMs = expires.millisecondsSinceEpoch;
      await jsonResponse(200, {
        'ok': true,
        'id': 'checkin-ci-1',
        'expiresAt': expires.toIso8601String(),
        'club': {'slug': clubSlug, 'name': clubName},
        'status': hasBearer ? 'approved' : 'guest',
        'needsSignup': !hasBearer,
        if (!hasBearer) 'deviceId': 'dev-ci',
        if (!hasBearer) 'token': deviceToken,
      });
      continue;
    }

    if (method == 'GET' && path == '/api/me/tails') {
      await jsonResponse(200, {
        'tails': [
          {'id': 'a1', 'tail': 'N12345', 'type_code': 'C172'},
        ],
      });
      continue;
    }

    if (method == 'GET' && path == '/api/me/flights') {
      final cookie = request.headers.value('cookie') ?? '';
      if (cookie.contains(session)) {
        await jsonResponse(200, {
          'flights': activeFlightId == null
              ? <Map<String, dynamic>>[]
              : [
                  {
                    'id': activeFlightId,
                    'tail': 'N12345',
                    'status': 'active',
                  },
                ],
        });
      } else {
        await jsonResponse(401, {'error': 'unauthorized'});
      }
      continue;
    }

    if (method == 'GET' && path == '/api/me/live-trails') {
      final layersRaw = request.uri.queryParameters['layers'] ?? 'club';
      final tokens = layersRaw.split(',');
      final valid = tokens.isNotEmpty &&
          tokens.every((t) => t == 'club' || t == 'public') &&
          tokens.toSet().length == tokens.length;
      if (!valid) {
        await jsonResponse(400, {'error': 'invalid layers'});
        continue;
      }
      final includeClub = tokens.contains('club');
      final includePublic = tokens.contains('public');
      int? effectiveRadiusKm;
      if (includePublic) {
        final lat = double.tryParse(request.uri.queryParameters['lat'] ?? '');
        final lon = double.tryParse(request.uri.queryParameters['lon'] ?? '');
        if (lat == null ||
            lon == null ||
            !lat.isFinite ||
            !lon.isFinite ||
            lat < -90 ||
            lat > 90 ||
            lon < -180 ||
            lon > 180) {
          await jsonResponse(400, {'error': 'lat and lon required for public layer'});
          continue;
        }
        final rawRadius = int.tryParse(request.uri.queryParameters['radius_km'] ?? '');
        effectiveRadiusKm = (rawRadius ?? 20).clamp(5, 500);
      }
      final etag = includePublic
          ? 'W/"mock-$layersRaw-r$effectiveRadiusKm"'
          : 'W/"mock-$layersRaw"';
      if (request.headers.value('if-none-match') == etag) {
        request.response.statusCode = 304;
        request.response.headers.set('etag', etag);
        await request.response.close();
        continue;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final flights = <Map<String, dynamic>>[
        if (includeClub)
          {
            'flightId': 'flt-club-1',
            'tail': 'CC-CLB',
            'layer': 'club',
            'trailMinutes': 5,
            'points': [
              [now - 180000, -33.448, -70.540, 880.0],
              [now - 90000, -33.445, -70.536, 910.0],
              [now - 10000, -33.442, -70.532, 930.0],
            ],
          },
        if (includePublic)
          {
            'flightId': 'flt-pub-1',
            'tail': 'CC-PUB',
            'layer': 'public',
            'trailMinutes': 5,
            'points': [
              [now - 180000, -33.465, -70.562, 1020.0],
              [now - 90000, -33.462, -70.558, 1040.0],
              [now - 10000, -33.459, -70.555, null],
            ],
          },
      ];
      request.response.headers.set('etag', etag);
      await jsonResponse(200, {
        'flights': flights,
        'caps': {
          'maxFlights': 50,
          'maxPointsPerFlight': 300,
          'maxWindowMinutes': 120,
        },
      });
      continue;
    }

    if (method == 'POST' && path == '/api/flights') {
      if (!checkinValid()) {
        await jsonResponse(403, {'error': 'check-in required'});
        continue;
      }
      if (activeFlightId != null) {
        await jsonResponse(409, {'error': 'flight already active'});
        continue;
      }
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final rawTrail = body['trailMinutes'];
      int? trail;
      if (rawTrail != null) {
        if (rawTrail is! int || !allowedTrailMinutes.contains(rawTrail)) {
          await jsonResponse(400, {'error': 'invalid trailMinutes'});
          continue;
        }
        trail = rawTrail;
      }
      activeFlightId = 'flight-ci-1';
      activeFlightTrailMinutes = trail;
      await jsonResponse(200, {
        'id': activeFlightId,
        'visibility': body['visibility'] ?? 'club',
        'showPilotNamePublic': body['show_pilot_name_public'] == true,
        'trailMinutes': activeFlightTrailMinutes,
      });
      continue;
    }

    final trailMatch = RegExp(r'^/api/flights/([^/]+)/trail$').firstMatch(path);
    if (method == 'PATCH' && trailMatch != null) {
      final flightId = trailMatch.group(1)!;
      if (activeFlightId == null || activeFlightId != flightId) {
        await jsonResponse(409, {'error': 'not active'});
        continue;
      }
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final rawTrail = body['trailMinutes'];
      if (rawTrail != null &&
          (rawTrail is! int || !allowedTrailMinutes.contains(rawTrail))) {
        await jsonResponse(400, {'error': 'invalid trailMinutes'});
        continue;
      }
      activeFlightTrailMinutes = rawTrail as int?;
      await jsonResponse(200, {'trailMinutes': activeFlightTrailMinutes});
      continue;
    }

    final endMatch = RegExp(r'^/api/flights/([^/]+)/end$').firstMatch(path);
    if (method == 'POST' && endMatch != null) {
      if (activeFlightId == null) {
        await jsonResponse(409, {'error': 'not active'});
        continue;
      }
      activeFlightId = null;
      activeFlightTrailMinutes = null;
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/club/logout') {
      await jsonResponse(200, {'ok': true});
      continue;
    }

    if (method == 'POST' && path == '/api/osmand') {
      final id = request.uri.queryParameters['id'] ?? '';
      if (id != deviceToken) {
        await jsonResponse(401, {'error': 'unauthorized'});
        continue;
      }
      await jsonResponse(200, {'ok': true});
      continue;
    }

    request.response.statusCode = 404;
    request.response.write('not found: $path');
    await request.response.close();
  }
}