import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/map/globe_bridge.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/widgets/tracking_map_card.dart';

import 'helpers/fake_globe_webview.dart';
import 'helpers/fake_tile_provider.dart';

class _MemSecure extends SecureStore {
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

Map<String, dynamic> _decodeJsPayload(String js) {
  final start = js.indexOf('(');
  final end = js.lastIndexOf(')');
  final literal = js.substring(start + 1, end).trim();
  return jsonDecode(jsonDecode(literal) as String) as Map<String, dynamic>;
}

Widget _wrap(Widget child) => PilotAppShell(home: Scaffold(body: child));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('2D/3D toggle persists and loads exact embed URL', (tester) async {
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _MemSecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: 'https://flight.heavenly.cl'),
    );
    final fake = FakeGlobeWebViewController();
    await tester.pumpWidget(
      _wrap(
        TrackingMapCard(
          client: repo.client,
          prefs: prefs,
          enable3dToggle: true,
          enablePolling: false,
          isOnline: () async => true,
          globeControllerFactory: () => fake,
          tileProvider: FakeTileProvider(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(FlightVisTestKeys.mapViewToggle2d), findsOneWidget);
    await tester.tap(find.byKey(FlightVisTestKeys.mapViewToggle3d));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(prefs.mapViewIs3d(), isTrue);
    expect(fake.lastLoadedUri?.toString(),
        'https://flight.heavenly.cl/embed/3d?ui=mobile&v=1');
    expect(find.byKey(FlightVisTestKeys.mapGlobeView), findsOneWidget);

    await tester.tap(find.byKey(FlightVisTestKeys.mapViewToggle2d));
    await tester.pumpAndSettle();
    expect(prefs.mapViewIs3d(), isFalse);
    expect(find.byKey(FlightVisTestKeys.mapGlobeView), findsNothing);
  });

  testWidgets('ready sends init and full snapshot without bearer/session tokens',
      (tester) async {
    const session = 'sess-bearer-leak-test';
    const device = '01234567890123456789012345678901';
    final prefs = await PreferencesStore.open();
    final client = FlightVisClient(
      baseUrl: 'https://flight.heavenly.cl',
      sessionId: session,
      deviceToken: device,
    );
    final fake = FakeGlobeWebViewController(autoEmitReady: false);
    await tester.pumpWidget(
      _wrap(
        TrackingMapCard(
          client: client,
          prefs: prefs,
          ownTail: 'CC-OWN',
          ownFlightId: 'flt-own',
          enable3dToggle: true,
          enablePolling: false,
          isOnline: () async => true,
          globeControllerFactory: () => fake,
          tileProvider: FakeTileProvider(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FlightVisTestKeys.mapViewToggle3d));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    fake.emitReady();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    for (final js in fake.javaScriptCalls) {
      expect(js, isNot(contains(session)));
      expect(js, isNot(contains(device)));
    }
    final init =
        fake.javaScriptCalls.map(_decodeJsPayload).firstWhere((m) => m['type'] == 'init');
    expect(init['protocol'], globeBridgeProtocolVersion);
    expect(init['ownFlightId'], 'flt-own');
    final flights = fake.javaScriptCalls
        .map(_decodeJsPayload)
        .firstWhere((m) => m['type'] == 'flights');
    expect(flights['mode'], 'full');
  });

  testWidgets('fallback on offline does not persist 3D preference', (tester) async {
    final prefs = await PreferencesStore.open();
    await prefs.setMapViewIs3d(false);
    final repo = AppRepository(
      secure: _MemSecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: 'https://flight.heavenly.cl'),
    );
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: TrackingMapCard(
            client: repo.client,
            prefs: prefs,
            enable3dToggle: true,
            enablePolling: false,
            isOnline: () async => false,
            globeControllerFactory: () => FakeGlobeWebViewController(),
            tileProvider: FakeTileProvider(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FlightVisTestKeys.mapViewToggle3d));
    await tester.pumpAndSettle();
    expect(find.byKey(FlightVisTestKeys.mapGlobeView), findsNothing);
    expect(prefs.mapViewIs3d(), isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}