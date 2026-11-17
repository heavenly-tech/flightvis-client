import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';

void main() {
  late Map<String, dynamic> contract;
  late Map<String, dynamic> magicSend;

  setUpAll(() {
    contract = jsonDecode(
      File('test/fixtures/flight_vis_server_contract.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    magicSend = jsonDecode(
      File('test/fixtures/contract/magic_send.json').readAsStringSync(),
    ) as Map<String, dynamic>;
  });

  test('client constants match server bd79692 contract (I-5)', () {
    final routes = contract['routes'] as Map<String, dynamic>;
    expect(magicSend['path'], FlightVisApiPaths.authMagicSend);
    expect(routes.containsKey('POST ${FlightVisApiPaths.authMagicSend}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.authMagicComplete}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.passkeyLoginOptions}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.passkeyLoginVerify}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.devicesAnonymous}'), isTrue);
    expect(routes.containsKey('GET /api/clubs/{slug}'), isTrue);
    final clubFixture = jsonDecode(
      File('test/fixtures/contract/club_by_slug.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(clubFixture['pathTemplate'], '/api/clubs/{slug}');
  });

  test('sendMagicLink hits POST /api/auth/magic/send', () async {
    String? path;
    String? body;
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        path = request.url.path;
        body = request.body;
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );
    await client.sendMagicLink('pilot@example.test');
    expect(path, FlightVisApiPaths.authMagicSend);
    expect(jsonDecode(body!), magicSend['body']);
  });

  test('completeMagicLink posts token to /api/auth/magic/complete', () async {
    String? path;
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        path = request.url.path;
        return http.Response(
          jsonEncode({
            'ok': true,
            'pilot': {
              'id': 'p1',
              'name': 'T',
              'email': 'a@b',
              'status': 'approved',
              'role': 'pilot',
            },
          }),
          200,
          headers: {'set-cookie': 'fv_club_session=sess; Path=/'},
        );
      }),
    );
    await client.completeMagicLink('tok123');
    expect(path, FlightVisApiPaths.authMagicComplete);
    expect(client.sessionId, 'sess');
  });

  test('fetchClub parses GET /api/clubs/{slug}', () async {
    final client = FlightVisClient(
      baseUrl: 'https://example.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/clubs/demo');
        return http.Response(
          jsonEncode({
            'club': {'id': 'c1', 'name': 'Demo', 'slug': 'demo', 'defaultLocale': 'es'},
            'userLocale': null,
          }),
          200,
        );
      }),
    );
    final club = await client.fetchClub('demo');
    expect(club.slug, 'demo');
    expect(club.name, 'Demo');
  });
}