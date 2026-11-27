import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/map/map_tile_config.dart';
import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/models/local_flight.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/local_flight_screen.dart';
import 'package:flight_vis/screens/local_flights_list_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/device_location_provider.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/flight_start_mode.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/local_flight_recorder.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/state/checkin_gate.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

import 'helpers/fake_tile_provider.dart';

class _FakeSecure extends SecureStore {
  String? _session;
  String? _device = '01234567890123456789012345678901';

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

class _FakeTracker extends Fake implements TraccarClientSdk {
  @override
  Future<void> init(Config config) async {}
  @override
  Future<void> setConfig(Config config) async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> isTracking() async => false;
  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  const trackingChannel = MethodChannel('cl.heavenly.flightvis/tracking');

  setUp(() {
    TrackingMapTestHooks.tileProviderOverride = FakeTileProvider();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, (_) async => null);
  });

  tearDown(() {
    TrackingMapTestHooks.tileProviderOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, null);
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

  group('M-25: per-account local flight buckets, legacy migration, move & delete', () {
    final pilotA = PilotProfile(
      id: 'pilot-alpha-123',
      name: 'Ana',
      email: 'ana.secret@club.cl',
      status: 'approved',
      role: 'pilot',
    );
    final pilotB = PilotProfile(
      id: 'pilot-bravo-456',
      name: 'Beto',
      email: 'beto.secret@club.cl',
      status: 'approved',
      role: 'pilot',
    );

    LocalFlight sampleFlight(String id, String tail, int startMs) => LocalFlight(
          id: id,
          startedAtMs: startMs,
          endedAtMs: startMs + 120_000,
          tail: tail,
          fixes: const [
            LocalFix(timeMs: 1000, latitude: -33.45, longitude: -70.55),
          ],
        );

    test('bucket isolation on disk: user A flights invisible to user B and guest, never embeds email', () async {
      final tempDir = await Directory.systemTemp.createTemp('fv_buckets_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      final bucketB = LocalFlightStore.bucketForPilot(pilotB);
      expect(LocalFlightStore.bucketForPilot(null), LocalFlightStore.guestBucket);
      expect(bucketA, isNot(LocalFlightStore.guestBucket));
      expect(bucketA, isNot(bucketB));
      expect(bucketA, isNot(contains('ana.secret')));
      expect(bucketA, isNot(contains('club.cl')));
      expect(bucketA, isNot(contains('pilot-alpha-123')));

      final store = FileLocalFlightStore(directoryProvider: () async => tempDir);
      await store.save(sampleFlight('f_a1', 'CC-AAA', 1000), bucket: bucketA);
      await store.save(sampleFlight('f_b1', 'CC-BBB', 2000), bucket: bucketB);
      await store.save(
        sampleFlight('f_g1', 'CC-GST', 3000),
        bucket: LocalFlightStore.guestBucket,
      );

      // Verify path structure <docs>/local_flights/<bucket>/<id>.json with no email in paths.
      final diskFiles = await tempDir
          .list(recursive: true)
          .where((e) => e is File && e.path.endsWith('.json'))
          .map((e) => e.path)
          .toList();
      expect(diskFiles, hasLength(3));
      for (final p in diskFiles) {
        expect(p, isNot(contains('ana.secret')));
        expect(p, isNot(contains('beto.secret')));
      }

      // User A sees only A; B sees only B; guest sees only guest.
      expect((await store.listFlights(bucket: bucketA)).map((f) => f.id), ['f_a1']);
      expect(await store.getFlight('f_b1', bucket: bucketA), isNull);
      expect(await store.getFlight('f_g1', bucket: bucketA), isNull);

      expect((await store.listFlights(bucket: bucketB)).map((f) => f.id), ['f_b1']);
      expect(await store.getFlight('f_a1', bucket: bucketB), isNull);

      expect(
        (await store.listFlights(bucket: LocalFlightStore.guestBucket))
            .map((f) => f.id),
        ['f_g1'],
      );
      expect(
        await store.getFlight('f_a1', bucket: LocalFlightStore.guestBucket),
        isNull,
      );
    });

    test('migrates legacy un-bucketed local_flights/*.json files into guest on first run', () async {
      final tempDir = await Directory.systemTemp.createTemp('fv_legacy_mig_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final legacyRoot = Directory(
        '${tempDir.path}${Platform.pathSeparator}local_flights',
      );
      await legacyRoot.create(recursive: true);
      final legacy1 = sampleFlight('legacy_1', 'CC-OLD', 5000);
      final legacy2 = sampleFlight('legacy_2', 'CC-TWO', 6000);
      await File('${legacyRoot.path}${Platform.pathSeparator}legacy_1.json')
          .writeAsString(jsonEncode(legacy1.toJson()));
      await File('${legacyRoot.path}${Platform.pathSeparator}legacy_2.json')
          .writeAsString(jsonEncode(legacy2.toJson()));

      final store = FileLocalFlightStore(directoryProvider: () async => tempDir);
      final bucketA = LocalFlightStore.bucketForPilot(pilotA);

      // Account bucket does not see migrated legacy files.
      expect(await store.listFlights(bucket: bucketA), isEmpty);

      // Guest bucket now owns both migrated files; root files are removed.
      final guestFlights =
          await store.listFlights(bucket: LocalFlightStore.guestBucket);
      expect(guestFlights.map((f) => f.id).toList(), ['legacy_2', 'legacy_1']);
      expect(
        await File('${legacyRoot.path}${Platform.pathSeparator}legacy_1.json')
            .exists(),
        isFalse,
      );
      expect(
        await File(
          '${legacyRoot.path}${Platform.pathSeparator}guest${Platform.pathSeparator}legacy_1.json',
        ).exists(),
        isTrue,
      );
    });

    testWidgets('signed-in Mis vuelos locales offers move-to-account vs keep-on-phone choice and per-flight delete', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      final bucketB = LocalFlightStore.bucketForPilot(pilotB);
      final store = InMemoryLocalFlightStore();
      await store.save(
        sampleFlight('g1', 'CC-G01', 1000),
        bucket: LocalFlightStore.guestBucket,
      );
      await store.save(
        sampleFlight('g2', 'CC-G02', 2000),
        bucket: LocalFlightStore.guestBucket,
      );
      await store.save(sampleFlight('b1', 'CC-OTR', 3000), bucket: bucketB);

      // 1. Open as pilot A -> sees banner for 2 guest flights, does NOT see pilot B's flight.
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-keep'),
            repo: repo,
            store: store,
            accountBucket: bucketA,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsOneWidget);
      expect(find.text('Tienes 2 vuelos guardados sin cuenta.'), findsOneWidget);
      expect(find.text('Guardar en mi cuenta'), findsOneWidget);
      expect(find.text('Dejarlos en este teléfono'), findsOneWidget);
      expect(find.text('CC-OTR'), findsNothing);

      // Choosing "Dejarlos en este teléfono" hides banner and keeps flights in guest bucket.
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsKeepOnPhone));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        hasLength(2),
      );
      expect(await store.listFlights(bucket: bucketA), isEmpty);

      // 2. Re-open as pilot A and choose "Guardar en mi cuenta" -> moves flights into account A.
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-move'),
            repo: repo,
            store: store,
            accountBucket: bucketA,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsMoveToAccount));
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );
      expect(await store.listFlights(bucket: bucketA), hasLength(2));
      expect(find.text('CC-G01'), findsOneWidget);
      expect(find.text('CC-G02'), findsOneWidget);

      // 3. Delete one flight with confirmation (first cancel, then confirm).
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightDelete('g1')));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightDeleteDialog), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('CC-G01'), findsOneWidget);

      await tester.tap(find.byKey(FlightVisTestKeys.localFlightDelete('g1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightDeleteConfirm));
      await tester.pumpAndSettle();

      expect(find.text('CC-G01'), findsNothing);
      expect(find.text('CC-G02'), findsOneWidget);
      expect((await store.listFlights(bucket: bucketA)).map((f) => f.id), ['g2']);
    });

    testWidgets('FlightVisApp sign-in prompts to move guest flights and logout isolates account tracks from guest', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _FakeSecure();
      final store = InMemoryLocalFlightStore();
      await store.save(
        sampleFlight('guest_1', 'CC-GST', 1000),
        bucket: LocalFlightStore.guestBucket,
      );

      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(
              jsonEncode({
                'email_verified': true,
                'pilot': {
                  'id': pilotA.id,
                  'name': pilotA.name,
                  'email': pilotA.email,
                  'status': 'approved',
                  'role': 'pilot',
                },
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.clubLogout) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final perms = _FakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: true,
          notificationsGranted: true,
          batteryUnrestricted: true,
        ),
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _FakeTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: perms,
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Simulate completing sign-in with an existing guest flight on device.
      await secure.writeSessionId('sess-ana');
      final onLoggedIn = flightVisAppOnLoggedInTestHook!;
      final loginFuture = onLoggedIn();
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsGuestDialog), findsOneWidget);
      expect(find.text('Tienes 1 vuelo guardado sin cuenta.'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsMoveToAccount));
      await tester.pumpAndSettle();
      await loginFuture;

      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      expect(await store.listFlights(bucket: bucketA), hasLength(1));
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );

      // Logout -> guest cannot see pilot A's tracks in "Mis vuelos locales".
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.text('CC-GST'), findsNothing);
      expect(
        find.text('Todavía no tienes vuelos guardados en este teléfono.'),
        findsOneWidget,
      );
    });
  });
}
