import 'dart:convert';
import 'dart:io';

/// Minimal club API mock for emulator integration screenshots (CI).
Future<void> main() async {
  const session = 'ci-mock-session';
  var checkedIn = false;

  final server = await HttpServer.bind(InternetAddress.anyIPv4, int.parse(
    Platform.environment['MOCK_PORT'] ?? '18080',
  ));
  // ignore: avoid_print
  print('mock flight_vis listening on ${server.port}');

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

    if (method == 'POST' && path == '/api/checkin') {
      checkedIn = true;
      final expires = DateTime.now().toUtc().add(const Duration(minutes: 30));
      await jsonResponse(200, {
        'ok': true,
        'expiresAt': expires.toIso8601String(),
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

    if (method == 'POST' && path == '/api/flights') {
      if (!checkedIn) {
        await jsonResponse(403, {'error': 'check-in required'});
        continue;
      }
      checkedIn = false;
      await jsonResponse(200, {
        'id': 'flight-ci-1',
        'visibility': 'club',
        'showPilotNamePublic': false,
      });
      continue;
    }

    if (method == 'POST' && path.startsWith('/api/flights/') && path.endsWith('/end')) {
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
    request.response.write('not found');
    await request.response.close();
  }
}