import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/map/map_tile_config.dart';
import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/models/local_flight.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/local_flight_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/device_location_provider.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/flight_start_mode.dart';
import 'package:flight_vis/services/local_flight_recorder.dart';
import 'package:flight_vis/state/checkin_gate.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

import 'helpers/fake_tile_provider.dart';

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

class _FakePermissions extends FlightPermissionsClient {
  _FakePermissions({
    required this.status,
    this.requestFineResult = false,
  });

  FlightPermissionStatus status;
  final bool requestFineResult;
  int requestFineCalls = 0;

  @override
  Future<FlightPermissionStatus> check() async => status;

  @override
  Future<bool> requestFineLocation() async {
    requestFineCalls++;
    if (requestFineResult) {
      status = FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: status.backgroundLocationGranted,
        notificationsGranted: status.notificationsGranted,
        batteryUnrestricted: status.batteryUnrestricted,
      );
    }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  setUp(() {
    TrackingMapTestHooks.tileProviderOverride = FakeTileProvider();
  });

  tearDown(() {
    TrackingMapTestHooks.tileProviderOverride = null;
  });

  group('FlightStartMode resolver', () {
    final approved = PilotProfile(
      id: 'p1',
      name: 'Pablo',
      email: 'pablo@club.cl',
      status: 'approved',
      role: 'pilot',
    );

    test('signed out -> localOnly(signedOut)', () {
      final res = resolveFlightStartMode(
        pilot: null,
        checkinGate: CheckinGate(expiresAtMs: null, nowMs: 1000),
      );
      expect(res.mode, FlightStartMode.localOnly);
      expect(res.localReason, LocalFlightReason.signedOut);
    });

    test('signed in without check-in -> localOnly(noClubCheckin)', () {
      final res = resolveFlightStartMode(
        pilot: approved,
        checkinGate: CheckinGate(expiresAtMs: null, nowMs: 1000),
      );
      expect(res.mode, FlightStartMode.localOnly);
      expect(res.localReason, LocalFlightReason.noClubCheckin);
    });

    test('signed in + valid check-in -> clubBroadcast', () {
      final res = resolveFlightStartMode(
        pilot: approved,
        checkinGate: CheckinGate(expiresAtMs: 5000, nowMs: 1000),
      );
      expect(res.mode, FlightStartMode.clubBroadcast);
      expect(res.localReason, isNull);
    });
  });

  group('LocalFlight model & FileLocalFlightStore persistence', () {
    test('sanitizes tail to uppercase [A-Z0-9-], max 16 chars', () {
      expect(LocalFlight.sanitizeTail('  cc-abc! '), 'CC-ABC');
      expect(LocalFlight.sanitizeTail('   '), isNull);
      expect(
        LocalFlight.sanitizeTail('cc-12345678901234567890'),
        'CC-1234567890123',
      );
    });

    test('persists start/end/tail/fixes to disk and survives reload with 50-flight cap', () async {
      final tempDir = await Directory.systemTemp.createTemp('fv_local_flights_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final store1 = FileLocalFlightStore(directoryProvider: () async => tempDir);
      final flight = LocalFlight(
        id: 'local_1000',
        startedAtMs: 1000,
        endedAtMs: 61000,
        tail: 'cc-xyz',
        fixes: const [
          LocalFix(timeMs: 2000, latitude: -33.45, longitude: -70.55, altitude: 920.5),
          LocalFix(timeMs: 32000, latitude: -33.44, longitude: -70.54, altitude: null),
        ],
      );
      await store1.save(flight);

      // Reopen a brand-new FileLocalFlightStore on the same directory.
      final store2 = FileLocalFlightStore(directoryProvider: () async => tempDir);
      final loaded = await store2.getFlight('local_1000');
      expect(loaded, isNotNull);
      expect(loaded!.startedAtMs, 1000);
      expect(loaded.endedAtMs, 61000);
      expect(loaded.tail, 'CC-XYZ');
      expect(loaded.uploaded, isFalse);
      expect(loaded.fixes, hasLength(2));
      expect(loaded.fixes[0].altitude, 920.5);
      expect(loaded.fixes[1].altitude, isNull);

      // Save 55 total flights -> store keeps newest 50 only.
      for (var i = 0; i < 55; i++) {
        await store2.save(
          LocalFlight(
            id: 'local_cap_$i',
            startedAtMs: 10_000 + i * 1000,
            endedAtMs: 10_500 + i * 1000,
            fixes: const [],
          ),
        );
      }
      final all = await store2.listFlights();
      expect(all.length, LocalFlightStore.maxStoredFlights);
      expect(all.first.id, 'local_cap_54');
      expect(all.last.id, 'local_cap_5');
    });
  });

  group('Iniciar vuelo modes on HomeHubScreen', () {
    testWidgets('signed-out Iniciar vuelo records locally with ZERO server calls and persists flight on stop', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final store = InMemoryLocalFlightStore();
      final recorder = FakeLocalFlightRecorder();
      addTearDown(recorder.dispose);

      final httpCalls = <http.Request>[];
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'must-not-use',
          deviceToken: 'must-not-use',
          httpClient: http_testing.MockClient((request) async {
            httpCalls.add(request);
            return http.Response(jsonEncode({'flights': []}), 200);
          }),
        ),
      );
      final perms = _FakePermissions(
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
          home: HomeHubScreen(
            repo: repo,
            pilot: null,
            onStartFlight: (_, _) => fail('must not use broadcast callback'),
            onRequestLogin: () {},
            onLogout: () {},
            permissions: perms,
            deviceLocationProvider: FakeDeviceLocationProvider(location: null),
            localRecorder: recorder,
            localFlightStore: store,
            tileProvider: FakeTileProvider(),
            enableMapPolling: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Missing battery/notifications/background only warn; Iniciar vuelo still works!
      expect(find.byKey(FlightVisTestKeys.permissionWarningCard), findsOneWidget);

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();

      // Enter optional tail and confirm start.
      expect(find.byKey(FlightVisTestKeys.localFlightStartDialog), findsOneWidget);
      await tester.enterText(
        find.byKey(FlightVisTestKeys.localFlightTailField),
        'cc-loc',
      );
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightConfirmStart));
      await tester.pumpAndSettle();

      expect(find.byType(LocalFlightScreen), findsOneWidget);
      expect(recorder.startCalls, 1);
      expect(find.text('Matrícula: CC-LOC'), findsOneWidget);

      // Emit local fixes during flight.
      recorder.emitFix(
        const LocalFix(
          timeMs: 1700000000000,
          latitude: -33.455,
          longitude: -70.548,
          altitude: 910.0,
        ),
      );
      recorder.emitFix(
        const LocalFix(
          timeMs: 1700000060000,
          latitude: -33.452,
          longitude: -70.545,
          altitude: 940.0,
        ),
      );
      await tester.pumpAndSettle();

      // Assert ZERO POST /api/flights and ZERO requests with auth headers!
      for (final req in httpCalls) {
        expect(req.url.path, isNot(FlightVisApiPaths.flights));
        expect(req.headers.containsKey('Cookie'), isFalse);
        expect(req.headers.containsKey('Authorization'), isFalse);
      }

      // Stop and confirm saving the local flight.
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightStop));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightStopConfirm));
      await tester.pumpAndSettle();

      expect(recorder.stopCalls, 1);
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);

      // Verify persisted flight in store with start/end/tail/fixes.
      final saved = await store.listFlights();
      expect(saved, hasLength(1));
      expect(saved.single.tail, 'CC-LOC');
      expect(saved.single.fixes, hasLength(2));
      expect(saved.single.endedAtMs, greaterThanOrEqualTo(saved.single.startedAtMs));

      // Verify "Mis vuelos locales" displays the saved flight and opens static map.
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsListScreen), findsOneWidget);
      expect(find.text('CC-LOC'), findsOneWidget);
      await tester.tap(find.text('CC-LOC'));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.trackingMap), findsOneWidget);
    });

    testWidgets('signed-in without check-in records locally and shows non-club note', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final store = InMemoryLocalFlightStore();
      final recorder = FakeLocalFlightRecorder();
      addTearDown(recorder.dispose);
      var postFlightsCalls = 0;

      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'sess-1',
          httpClient: http_testing.MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.flights) {
              postFlightsCalls++;
            }
            return http.Response(jsonEncode({'flights': []}), 200);
          }),
        ),
      );
      final pilot = PilotProfile(
        id: 'p1',
        name: 'Pablo',
        email: 'pablo@club.cl',
        status: 'approved',
        role: 'pilot',
      );
      final perms = _FakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: true,
          notificationsGranted: true,
          batteryUnrestricted: true,
        ),
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: HomeHubScreen(
            repo: repo,
            pilot: pilot,
            onStartFlight: (_, _) => fail('must not broadcast without check-in'),
            onRequestLogin: () {},
            onLogout: () {},
            permissions: perms,
            localRecorder: recorder,
            localFlightStore: store,
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();
      expect(
        find.text('Vuelo sin club: se guarda en tu teléfono. Pronto se podrá subir.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(FlightVisTestKeys.localFlightConfirmStart));
      await tester.pumpAndSettle();

      expect(find.byType(LocalFlightScreen), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.localFlightNoClubNote), findsOneWidget);
      expect(
        find.text('Vuelo sin club: se guarda en tu teléfono. Pronto se podrá subir.'),
        findsOneWidget,
      );
      expect(recorder.startCalls, 1);
      expect(postFlightsCalls, 0);
    });

    testWidgets('signed-in + valid check-in Iniciar vuelo uses broadcast flow (POST /api/flights)', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.checkinExpiresAtKey:
            DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
      });
      final prefs = await PreferencesStore.open();
      var postFlightsCalls = 0;
      String? broadcastFlightId;
      String? broadcastTail;

      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'sess-1',
          httpClient: http_testing.MockClient((request) async {
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
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.flights) {
              postFlightsCalls++;
              return http.Response(
                jsonEncode({
                  'id': 'flt-club-broadcast',
                  'visibility': 'club',
                  'showPilotNamePublic': false,
                }),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        ),
      );
      final pilot = PilotProfile(
        id: 'p1',
        name: 'Pablo',
        email: 'pablo@club.cl',
        status: 'approved',
        role: 'pilot',
      );
      final perms = _FakePermissions(
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
          home: HomeHubScreen(
            repo: repo,
            pilot: pilot,
            onStartFlight: (id, tail) {
              broadcastFlightId = id;
              broadcastTail = tail;
            },
            onRequestLogin: () {},
            onLogout: () {},
            permissions: perms,
            localFlightStore: InMemoryLocalFlightStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();

      expect(find.byType(TailPickerScreen), findsOneWidget);
      await tester.ensureVisible(find.byKey(FlightVisTestKeys.tailStart));
      await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
      await tester.pumpAndSettle();

      expect(postFlightsCalls, 1);
      expect(broadcastFlightId, 'flt-club-broadcast');
      expect(broadcastTail, 'CC-ABC');
    });

    testWidgets('Iniciar vuelo blocks with message when fine location is denied', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final recorder = FakeLocalFlightRecorder();
      addTearDown(recorder.dispose);
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      final perms = _FakePermissions(
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
          home: HomeHubScreen(
            repo: repo,
            pilot: null,
            onStartFlight: (_, _) {},
            onRequestLogin: () {},
            onLogout: () {},
            permissions: perms,
            localRecorder: recorder,
            localFlightStore: InMemoryLocalFlightStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();

      expect(perms.requestFineCalls, 1);
      expect(recorder.startCalls, 0);
      expect(find.byKey(FlightVisTestKeys.hubStartError), findsOneWidget);
      expect(
        find.text('Necesitas permiso de ubicación para iniciar el vuelo.'),
        findsOneWidget,
      );
    });
  });
}
