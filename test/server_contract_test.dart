import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';

void main() {
  late Map<String, dynamic> contract;

  setUpAll(() {
    final raw = File('test/fixtures/flight_vis_server_contract.json').readAsStringSync();
    contract = jsonDecode(raw) as Map<String, dynamic>;
  });

  test('client path constants match server contract document', () {
    final routes = contract['routes'] as Map<String, dynamic>;
    expect(routes.containsKey('POST ${FlightVisApiPaths.authMagicLink}'), isTrue);
    expect(routes.containsKey('GET ${FlightVisApiPaths.authMagicConsume}?token='), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.webauthnLoginBegin}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.webauthnLoginFinish}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.devicesAnonymous}'), isTrue);
    expect(routes.containsKey('POST ${FlightVisApiPaths.meDevices}'), isTrue);
    expect(routes.containsKey('GET /api/clubs/{slug}'), isTrue);
    expect(routes['POST /api/flights/{id}/end'], isNotNull);
  });
}