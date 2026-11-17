import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/screens/login_screen.dart';
import 'package:flight_vis/screens/pairing_screen.dart';
import 'package:flight_vis/screens/checkin_screen.dart';
import 'package:flight_vis/screens/permissions_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => null;
  @override
  Future<String?> readSessionId() async => null;
  @override
  Future<void> writeDeviceToken(String token) async {}
  @override
  Future<void> clearDeviceToken() async {}
  @override
  Future<void> writeSessionId(String sessionId) async {}
  @override
  Future<void> clearSessionId() async {}
  @override
  Future<void> clearAll() async {}
}

Future<AppRepository> _repo() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await PreferencesStore.open();
  return AppRepository(
    secure: _FakeSecure(),
    prefs: prefs,
    client: FlightVisClient(baseUrl: prefs.baseUrl()),
  );
}

Future<void> _golden(WidgetTester tester, Widget home, String name) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../docs/screenshots/$name.png'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('login golden', (tester) async {
    final repo = await _repo();
    await _golden(
      tester,
      LoginScreen(repo: repo, onLoggedIn: () {}),
      '01-login',
    );
  });

  testWidgets('pairing golden', (tester) async {
    final repo = await _repo();
    await _golden(
      tester,
      PairingScreen(repo: repo, onPaired: () {}),
      '02-pairing',
    );
  });

  testWidgets('checkin golden', (tester) async {
    final repo = await _repo();
    await _golden(
      tester,
      CheckinScreen(repo: repo, onCheckedIn: () {}),
      '03-checkin',
    );
  });

  testWidgets('permissions golden', (tester) async {
    await _golden(
      tester,
      PermissionsScreen(onContinue: () {}),
      '04-permissions',
    );
  });

  testWidgets('tail picker golden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final client = FlightVisClient(
      baseUrl: prefs.baseUrl(),
      httpClient: http_testing.MockClient((request) async {
        if (request.url.path == '/api/me/tails') {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'N12345', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    final repo = AppRepository(secure: _FakeSecure(), prefs: prefs, client: client);
    await _golden(
      tester,
      TailPickerScreen(repo: repo, onFlightStarted: (_, __) {}),
      '05-tail-picker',
    );
  });

  testWidgets('tracking active golden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _FakeSecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: prefs.baseUrl()),
    );
    await _golden(
      tester,
      TrackingScreen(
        repo: repo,
        flightId: 'flight-demo',
        tail: 'N12345',
        tracking: TrackingService(),
        onStopped: () {},
      ),
      '06-tracking',
    );
  });
}