import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/screens/checkin_screen.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

const _kioskToken = 'v1.club1.999999.abcdef0123456789abcdef0123456789';
const _deviceToken = '01234567890123456789012345678901';

class _MemorySecure extends SecureStore {
  String? _device = _deviceToken;
  String? _session;

  @override
  Future<String?> readDeviceToken() async => _device;
  @override
  Future<String?> readSessionId() async => _session;
  @override
  Future<void> writeDeviceToken(String token) async => _device = token;
  @override
  Future<void> clearDeviceToken() async => _device = null;
  @override
  Future<void> writeSessionId(String sessionId) async => _session = sessionId;
  @override
  Future<void> clearSessionId() async => _session = null;
  @override
  Future<void> clearAll() async {
    _device = null;
    _session = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  testWidgets('CheckinScreen places scan QR button under intro and collapses manual paste', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _MemorySecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: prefs.baseUrl(), deviceToken: _deviceToken),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: CheckinScreen(repo: repo, onCheckedIn: () {}),
      ),
    );
    await tester.pump();

    final introFinder = find.textContaining('Escanea el QR rotativo');
    final scanBtnFinder = find.text('Escanear QR de registro');
    final manualTileFinder = find.byKey(FlightVisTestKeys.checkinManualEntry);

    expect(introFinder, findsOneWidget);
    expect(scanBtnFinder, findsOneWidget);
    expect(manualTileFinder, findsOneWidget);
    expect(find.text('¿No funciona la cámara? Pegar código manual'), findsOneWidget);

    // Primary scan button directly under intro copy and above manual tile.
    expect(tester.getTopLeft(introFinder).dy, lessThan(tester.getTopLeft(scanBtnFinder).dy));
    expect(tester.getTopLeft(scanBtnFinder).dy, lessThan(tester.getTopLeft(manualTileFinder).dy));

    // Manual paste TextField is hidden while ExpansionTile is collapsed.
    expect(find.byKey(FlightVisTestKeys.checkinPasteField), findsNothing);
    expect(find.byKey(FlightVisTestKeys.checkinPasteSubmit), findsNothing);

    // Expanding shows paste TextField + submit button.
    await tester.tap(manualTileFinder);
    await tester.pumpAndSettle();

    expect(find.byKey(FlightVisTestKeys.checkinPasteField), findsOneWidget);
    expect(find.byKey(FlightVisTestKeys.checkinPasteSubmit), findsOneWidget);
    expect(find.text('Enviar código'), findsOneWidget);
  });

  testWidgets('CheckinScreen Continuar replaces route with TailPickerScreen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final client = FlightVisClient(
      baseUrl: prefs.baseUrl(),
      deviceToken: _deviceToken,
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.checkin) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'expiresAt': '2099-01-01T15:00:00Z',
              'club': {'slug': 'demo-club', 'name': 'Club Demo'},
            }),
            200,
          );
        }
        if (request.method == 'GET' && request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-XYZ', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          return http.Response(
            jsonEncode({
              'id': 'flight-42',
              'visibility': 'club',
              'showPilotNamePublic': false,
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    final repo = AppRepository(secure: _MemorySecure(), prefs: prefs, client: client);

    String? startedFlightId;
    String? startedTail;

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: HomeHubScreen(
          repo: repo,
          onStartFlight: (id, tail) {
            startedFlightId = id;
            startedTail = tail;
          },
          onRequestLogin: () {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();

    // Open CheckinScreen from HomeHubScreen.
    await tester.tap(find.byKey(FlightVisTestKeys.hubCheckIn));
    await tester.pumpAndSettle();
    expect(find.byType(CheckinScreen), findsOneWidget);

    // Expand manual code entry and submit check-in.
    await tester.tap(find.byKey(FlightVisTestKeys.checkinManualEntry));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(FlightVisTestKeys.checkinPasteField), _kioskToken);
    await tester.tap(find.byKey(FlightVisTestKeys.checkinPasteSubmit));
    await tester.pumpAndSettle();

    expect(find.byKey(FlightVisTestKeys.checkinContinue), findsOneWidget);

    // Tapping Continuar replaces CheckinScreen directly with TailPickerScreen.
    await tester.tap(find.byKey(FlightVisTestKeys.checkinContinue));
    await tester.pumpAndSettle();

    expect(find.byType(TailPickerScreen), findsOneWidget);
    expect(find.byType(CheckinScreen), findsNothing);
    expect(find.text('CC-XYZ (C172)'), findsOneWidget);

    // Starting flight invokes HomeHubScreen's onStartFlight callback.
    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(startedFlightId, 'flight-42');
    expect(startedTail, 'CC-XYZ');
    expect(find.byType(HomeHubScreen), findsOneWidget);
  });

  testWidgets('HomeHubScreen shows locked subtitle on Detalles del vuelo when gate blocks flight', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _MemorySecure(),
      prefs: prefs,
      client: FlightVisClient(baseUrl: prefs.baseUrl()),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: HomeHubScreen(
          repo: repo,
          onStartFlight: (_, _) {},
          onRequestLogin: () {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();

    final tile = tester.widget<ListTile>(find.byKey(FlightVisTestKeys.hubFlightDetails));
    expect(tile.enabled, isFalse);
    expect(find.text('Escanea primero el QR del club para desbloquear.'), findsOneWidget);
    expect(find.text('Elige matrícula y visibilidad, luego comienza'), findsNothing);

    // Grant valid check-in and re-render.
    await prefs.setCheckinExpiresAtMs(DateTime.now().millisecondsSinceEpoch + 3600 * 1000);
    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: HomeHubScreen(
          key: const ValueKey('hub-unlocked'),
          repo: repo,
          onStartFlight: (_, _) {},
          onRequestLogin: () {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();

    final unlockedTile = tester.widget<ListTile>(find.byKey(FlightVisTestKeys.hubFlightDetails));
    expect(unlockedTile.enabled, isTrue);
    expect(find.text('Escanea primero el QR del club para desbloquear.'), findsNothing);
    expect(find.text('Elige matrícula y visibilidad, luego comienza'), findsOneWidget);
  });
}
