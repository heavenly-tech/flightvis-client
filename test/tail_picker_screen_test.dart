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
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => '01234567890123456789012345678901';
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

Future<AppRepository> _buildRepo(
  http.Client httpClient, {
  bool validCheckin = true,
}) async {
  final futureMs = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
  SharedPreferences.setMockInitialValues({});
  final prefs = await PreferencesStore.open();
  if (validCheckin) {
    await prefs.setCheckinExpiresAtMs(futureMs);
  }
  return AppRepository(
    secure: _FakeSecure(),
    prefs: prefs,
    client: FlightVisClient(
      baseUrl: prefs.baseUrl(),
      httpClient: httpClient,
      deviceToken: '01234567890123456789012345678901',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('empty tails renders inline empty-state card and Actualizar reloads', (tester) async {
    var calls = 0;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          calls++;
          if (calls == 1) {
            return http.Response(jsonEncode({'tails': []}), 200);
          }
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(
      find.text('No tienes matrículas habilitadas en este club. Pídele una habilitación a un administrador.'),
      findsOneWidget,
    );
    expect(find.text('Actualizar'), findsOneWidget);

    await tester.tap(find.text('Actualizar'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(
      find.text('No tienes matrículas habilitadas en este club. Pídele una habilitación a un administrador.'),
      findsNothing,
    );
    expect(find.text('CC-ABC (C172)'), findsOneWidget);
  });

  testWidgets('does not render empty-state card when loading tails errors', (tester) async {
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No tienes matrículas habilitadas en este club. Pídele una habilitación a un administrador.'),
      findsNothing,
    );
    expect(find.text('Debes iniciar sesión para continuar.'), findsOneWidget);
  });

  testWidgets('public-name switch only shows for public visibility and resets/sends false otherwise', (tester) async {
    Map<String, dynamic>? lastStartBody;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          lastStartBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'f-1',
              'visibility': lastStartBody!['visibility'],
              'showPilotNamePublic': lastStartBody!['show_pilot_name_public'],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    var started = false;
    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) => started = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Default visibility is 'club': switch must be hidden.
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Mostrar nombre en mapa público'), findsNothing);

    // Switch visibility to 'public': switch appears, initially false.
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Público').last);
    await tester.pumpAndSettle();

    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);

    // Enable the switch.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);

    // Switch visibility back to 'private': switch hides and resets to false.
    await tester.tap(find.text('Público'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privado').last);
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);

    // Re-selecting 'public' confirms _showPilotNamePublic was reset to false.
    await tester.tap(find.text('Privado'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Público').last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);

    // Enable again, switch back to 'club', and start flight -> server receives false.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);

    await tester.tap(find.text('Público'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Club').last);
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(started, isTrue);
    expect(lastStartBody, isNotNull);
    expect(lastStartBody!['visibility'], 'club');
    expect(lastStartBody!['show_pilot_name_public'], isFalse);
  });

  testWidgets('public visibility with switch on sends show_pilot_name_public true', (tester) async {
    Map<String, dynamic>? lastStartBody;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          lastStartBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'f-2',
              'visibility': 'public',
              'showPilotNamePublic': true,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Público').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(lastStartBody!['visibility'], 'public');
    expect(lastStartBody!['show_pilot_name_public'], isTrue);
  });

  testWidgets('wraps body in SingleChildScrollView with no overflow on small screen', (tester) async {
    tester.view.physicalSize = const Size(320, 380);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(jsonEncode({'tails': []}), 200);
        }
        return http.Response('{}', 404);
      }),
      validCheckin: false,
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trail chips default to club default (omits trailMinutes) and show club default label', (tester) async {
    Map<String, dynamic>? lastStartBody;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          lastStartBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'f-default',
              'visibility': 'club',
              'showPilotNamePublic': false,
              'trailMinutes': null,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    repo.client.setClubTrailMinutesDefault(5);

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Estela en el mapa'), findsOneWidget);
    expect(find.text('Usar predeterminado del club (5 min)'), findsOneWidget);
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(null))).selected,
      isTrue,
    );

    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(lastStartBody, isNotNull);
    expect(lastStartBody!.containsKey('trailMinutes'), isFalse);
    expect(repo.prefs.activeFlightTrailMinutes(), isNull);
  });

  testWidgets('selecting a trail chip sends trailMinutes on POST /api/flights and persists it', (tester) async {
    Map<String, dynamic>? lastStartBody;
    StartFlightResult? startedFlight;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          lastStartBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'f-trail',
              'visibility': 'club',
              'showPilotNamePublic': false,
              'trailMinutes': lastStartBody!['trailMinutes'],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          onFlightStarted: (flight, _) => startedFlight = flight,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(FlightVisTestKeys.trailChip(15)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(15))).selected,
      isTrue,
    );

    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(lastStartBody, isNotNull);
    expect(lastStartBody!['trailMinutes'], 15);
    expect(startedFlight?.trailMinutes, 15);
    expect(repo.prefs.activeFlightTrailMinutes(), 15);
  });

  testWidgets('Start proceeds when battery, notifications, and background are missing but fine is granted', (tester) async {
    var startFlightCalls = 0;
    StartFlightResult? startedFlight;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          startFlightCalls++;
          return http.Response(
            jsonEncode({
              'id': 'f-warn-only',
              'visibility': 'club',
              'showPilotNamePublic': false,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    final perms = _TailTestPermissions(
      status: const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: false,
        notificationsGranted: false,
        batteryUnrestricted: false,
      ),
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          permissions: perms,
          onFlightStarted: (flight, _) => startedFlight = flight,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Banner warns, but Start is NOT blocked.
    expect(find.byKey(FlightVisTestKeys.permissionWarningCard), findsOneWidget);

    await tester.ensureVisible(find.byKey(FlightVisTestKeys.tailStart));
    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(startFlightCalls, 1);
    expect(startedFlight?.id, 'f-warn-only');
  });

  testWidgets('Start is blocked with a clear message when fine location is denied', (tester) async {
    var startFlightCalls = 0;
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.path == FlightVisApiPaths.flights) {
          startFlightCalls++;
          return http.Response(jsonEncode({'id': 'should-not-happen'}), 200);
        }
        return http.Response('{}', 404);
      }),
    );

    final perms = _TailTestPermissions(
      status: const FlightPermissionStatus(
        fineLocationGranted: false,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      ),
      requestFineResult: false,
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          permissions: perms,
          onFlightStarted: (_, _) => fail('must not start without fine location'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(FlightVisTestKeys.tailStart));
    await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
    await tester.pumpAndSettle();

    expect(perms.requestFineCalls, 1);
    expect(startFlightCalls, 0);
    expect(
      find.text('Necesitas permiso de ubicación para iniciar el vuelo.'),
      findsOneWidget,
    );
  });

  testWidgets('hides public visibility option when pilot email is unverified', (tester) async {
    final repo = await _buildRepo(
      http_testing.MockClient((request) async {
        if (request.url.path == FlightVisApiPaths.meTails) {
          return http.Response(
            jsonEncode({
              'tails': [
                {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    final unverifiedPilot = PilotProfile(
      id: 'p-unv',
      name: 'Unverified',
      email: 'pilot@example.test',
      status: 'approved',
      role: 'pilot',
      emailVerified: false,
    );

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TailPickerScreen(
          repo: repo,
          pilot: unverifiedPilot,
          onFlightStarted: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Verifica tu correo para transmitir de forma pública.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();
    expect(find.text('Público'), findsNothing);
    expect(find.text('Privado'), findsOneWidget);
  });
}

class _TailTestPermissions extends FlightPermissionsClient {
  _TailTestPermissions({
    required this.status,
    this.requestFineResult = true,
  });

  FlightPermissionStatus status;
  final bool requestFineResult;
  int requestFineCalls = 0;

  @override
  Future<FlightPermissionStatus> check() async => status;

  @override
  Future<bool> requestFineLocation() async {
    requestFineCalls++;
    return requestFineResult;
  }

  @override
  Future<bool> requestBackgroundLocation() async => true;

  @override
  Future<bool> requestNotifications() async => true;

  @override
  Future<bool> requestBatteryExemption() async => true;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<void> openGapSettings(PermissionGap gap) async {}
}
