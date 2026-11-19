import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CI mock /api/devices/anonymous returns pilot + Set-Cookie (I-5)', () {
    final src = File('tool/mock_flight_vis_server.dart').readAsStringSync();
    expect(src, contains("path == '/api/devices/anonymous'"));
    expect(src, contains("'ok': true"));
    expect(src, contains("'pilot':"));
    expect(src, contains('fv_club_session'));
    final start = src.indexOf("path == '/api/devices/anonymous'");
    final end = src.indexOf('continue;', start);
    final block = src.substring(start, end);
    expect(block, contains("'ok': true"));
    expect(block, contains("'pilot':"));
    expect(block, contains('cookie: session'));
    expect(block, isNot(contains("'token':")));
    expect(block, isNot(contains("'id': 'dev-ci'")));
  });
}