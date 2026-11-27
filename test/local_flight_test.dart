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
import 'package:flight_vis/storage/local_flight_migration.dart';
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
        find.text('Vuelo sin club: se guarda en tu teléfono. Pronto podrás subirlo.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(FlightVisTestKeys.localFlightConfirmStart));
      await tester.pumpAndSettle();

      expect(find.byType(LocalFlightScreen), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.localFlightNoClubNote), findsOneWidget);
      expect(
        find.text('Vuelo sin club: se guarda en tu teléfono. Pronto podrás subirlo.'),
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

    test('M-28: reserves legacy bucket and migrates pre-#11 root files into legacy/ (never guest/)', () async {
      final tempDir = await Directory.systemTemp.createTemp('fv_legacy_mig_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      // Reserved bucket guards: sanitizeBucket and pilot hashes can never produce "legacy".
      expect(LocalFlightStore.isReservedBucket('legacy'), isTrue);
      expect(LocalFlightStore.isReservedBucket('LEGACY'), isTrue);
      expect(LocalFlightStore.isReservedBucket('  Legacy  '), isTrue);
      expect(LocalFlightStore.isReservedBucket('guest'), isFalse);
      expect(
        LocalFlightStore.sanitizeBucket('legacy'),
        LocalFlightStore.guestBucket,
      );
      expect(
        LocalFlightStore.sanitizeBucket('LEGACY'),
        LocalFlightStore.guestBucket,
      );
      expect(
        LocalFlightStore.sanitizeBucket('  Legacy  '),
        LocalFlightStore.guestBucket,
      );
      final hashOfLegacy = LocalFlightStore.bucketForPilotId('legacy');
      expect(hashOfLegacy, startsWith('acct_'));
      expect(hashOfLegacy.toLowerCase(), isNot(LocalFlightStore.legacyBucket));

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

      // Account and guest buckets do NOT see migrated legacy files.
      expect(await store.listFlights(bucket: bucketA), isEmpty);
      expect(await store.listFlights(bucket: LocalFlightStore.guestBucket), isEmpty);
      expect(await store.listFlights(bucket: LocalFlightStore.legacyBucket), isEmpty);
      expect(await store.getFlight('legacy_1', bucket: LocalFlightStore.guestBucket), isNull);
      expect(await store.getFlight('legacy_1', bucket: LocalFlightStore.legacyBucket), isNull);

      // Root files were moved into local_flights/legacy/ (NOT local_flights/guest/).
      expect(await store.countLegacyFlights(), 2);
      expect(
        await File('${legacyRoot.path}${Platform.pathSeparator}legacy_1.json')
            .exists(),
        isFalse,
      );
      expect(
        await File(
          '${legacyRoot.path}${Platform.pathSeparator}guest${Platform.pathSeparator}legacy_1.json',
        ).exists(),
        isFalse,
      );
      expect(
        await File(
          '${legacyRoot.path}${Platform.pathSeparator}legacy${Platform.pathSeparator}legacy_1.json',
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          '${legacyRoot.path}${Platform.pathSeparator}legacy${Platform.pathSeparator}legacy_2.json',
        ).exists(),
        isTrue,
      );

      // Standard save/move APIs can never write to or read from legacy/.
      await store.save(
        sampleFlight('g_only', 'CC-GST', 7000),
        bucket: LocalFlightStore.legacyBucket,
      );
      expect(
        (await store.listFlights(bucket: LocalFlightStore.guestBucket))
            .map((f) => f.id)
            .toList(),
        ['g_only'],
      );
      expect(await store.countLegacyFlights(), 2);
      expect(
        await store.moveFlights(
          fromBucket: LocalFlightStore.legacyBucket,
          toBucket: bucketA,
        ),
        0,
      );
      expect(
        await store.moveFlights(
          fromBucket: LocalFlightStore.guestBucket,
          toBucket: LocalFlightStore.legacyBucket,
        ),
        0,
      );
      // Guest flight was NOT accidentally moved when fromBucket was 'legacy'.
      expect(
        (await store.listFlights(bucket: LocalFlightStore.guestBucket))
            .map((f) => f.id)
            .toList(),
        ['g_only'],
      );
      expect(await store.listFlights(bucket: bucketA), isEmpty);

      // adoptLegacyFlights refuses guest and reserved buckets.
      await expectLater(
        () => store.adoptLegacyFlights(toBucket: LocalFlightStore.guestBucket),
        throwsArgumentError,
      );
      await expectLater(
        () => store.adoptLegacyFlights(toBucket: LocalFlightStore.legacyBucket),
        throwsArgumentError,
      );
    });

    testWidgets('M-25/M-28: "Dejarlos en este teléfono" persists real state, keeps guest flights in guest, never surfaces legacy, and supports move + delete', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      final bucketB = LocalFlightStore.bucketForPilot(pilotB);
      final store = InMemoryLocalFlightStore(
        initialLegacy: [sampleFlight('old_leg', 'CC-LEG', 500)],
      );
      // Mark legacy claimed by a third account so this test isolates guest behavior.
      await prefs.setLegacyFlightsClaimantBucket('acct_other_claimant');
      await store.save(
        sampleFlight('g1', 'CC-G01', 1000),
        bucket: LocalFlightStore.guestBucket,
      );
      await store.save(
        sampleFlight('g2', 'CC-G02', 2000),
        bucket: LocalFlightStore.guestBucket,
      );
      await store.save(sampleFlight('b1', 'CC-OTR', 3000), bucket: bucketB);

      // 0. Guest view sees real guest flights ONLY, never legacy flights and no banner.
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-guest'),
            repo: repo,
            store: store,
            accountBucket: LocalFlightStore.guestBucket,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CC-G01'), findsOneWidget);
      expect(find.text('CC-G02'), findsOneWidget);
      expect(find.text('CC-LEG'), findsNothing);
      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);

      // 1. Open as pilot A -> sees guest banner for 2 flights, does NOT see pilot B or legacy.
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
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.text('Tienes 2 vuelos guardados sin cuenta.'), findsOneWidget);
      expect(find.text('Guardar en mi cuenta'), findsOneWidget);
      expect(find.text('Dejarlos en este teléfono'), findsOneWidget);
      expect(find.text('CC-OTR'), findsNothing);
      expect(find.text('CC-LEG'), findsNothing);

      // Choosing "Dejarlos en este teléfono" persists the choice for pilot A and keeps flights in guest.
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsKeepOnPhone));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        hasLength(2),
      );
      expect(await store.listFlights(bucket: bucketA), isEmpty);
      expect(prefs.keptOnPhoneGuestFlightIds(bucketA), {'g1', 'g2'});

      // Re-opening as pilot A with a freshly opened PreferencesStore keeps the banner gone.
      final reloadedPrefs = await PreferencesStore.open();
      final reloadedRepo = AppRepository(
        secure: _FakeSecure(),
        prefs: reloadedPrefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-keep-reopened'),
            repo: reloadedRepo,
            store: store,
            accountBucket: bucketA,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);

      // Recording a new guest flight g3 offers ONLY g3 to pilot A and moves only g3.
      await store.save(
        sampleFlight('g3', 'CC-G03', 2500),
        bucket: LocalFlightStore.guestBucket,
      );
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-new-guest'),
            repo: reloadedRepo,
            store: store,
            accountBucket: bucketA,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tienes 1 vuelo guardado sin cuenta.'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsMoveToAccount));
      await tester.pumpAndSettle();
      expect((await store.listFlights(bucket: bucketA)).map((f) => f.id), ['g3']);
      expect(
        (await store.listFlights(bucket: LocalFlightStore.guestBucket))
            .map((f) => f.id)
            .toList(),
        ['g2', 'g1'],
      );

      // 2. Pilot B (who hasn't declined g1/g2) adopts g1 & g2 into bucketB.
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LocalFlightsListScreen(
            key: const ValueKey('list-move-b'),
            repo: reloadedRepo,
            store: store,
            accountBucket: bucketB,
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tienes 2 vuelos guardados sin cuenta.'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsMoveToAccount));
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );
      expect(await store.listFlights(bucket: bucketB), hasLength(3));
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
      expect(
        (await store.listFlights(bucket: bucketB)).map((f) => f.id).toList(),
        ['b1', 'g2'],
      );
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

  group('M-28: disk-backed FileLocalFlightStore + PreferencesStore legacy lifecycle', () {
    final pilotA = PilotProfile(
      id: 'pilot-alpha-123',
      name: 'Ana',
      email: 'ana@club.cl',
      status: 'approved',
      role: 'pilot',
    );
    final pilotB = PilotProfile(
      id: 'pilot-bravo-456',
      name: 'Beto',
      email: 'beto@club.cl',
      status: 'approved',
      role: 'pilot',
    );
    final bucketA = LocalFlightStore.bucketForPilot(pilotA);
    final bucketB = LocalFlightStore.bucketForPilot(pilotB);

    LocalFlight sampleFlight(String id, String tail, int startMs) => LocalFlight(
          id: id,
          startedAtMs: startMs,
          endedAtMs: startMs + 120_000,
          tail: tail,
          fixes: const [
            LocalFix(timeMs: 1000, latitude: -33.45, longitude: -70.55),
          ],
        );

    Future<Directory> seedLegacyRootDir() async {
      final tempDir = await Directory.systemTemp.createTemp('fv_m28_disk_');
      final legacyRoot = Directory(
        '${tempDir.path}${Platform.pathSeparator}local_flights',
      );
      await legacyRoot.create(recursive: true);
      await File('${legacyRoot.path}${Platform.pathSeparator}legacy_1.json')
          .writeAsString(
        jsonEncode(sampleFlight('legacy_1', 'CC-OLD', 5000).toJson()),
      );
      await File('${legacyRoot.path}${Platform.pathSeparator}legacy_2.json')
          .writeAsString(
        jsonEncode(sampleFlight('legacy_2', 'CC-TWO', 6000).toJson()),
      );
      return tempDir;
    }

    test('adopt-once on disk: first account adopts, marker & isolation persist across FileLocalFlightStore and PreferencesStore reopen', () async {
      final tempDir = await seedLegacyRootDir();
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final store = FileLocalFlightStore(directoryProvider: () async => tempDir);

      // Guest before sign-in cannot see or claim legacy files.
      expect(await store.listFlights(bucket: LocalFlightStore.guestBucket), isEmpty);
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: LocalFlightStore.guestBucket,
        ),
        0,
      );
      expect(prefs.legacyFlightsClaimantBucket(), isNull);
      expect(prefs.legacyFlightsResolved(), isFalse);

      // First signed-in account (A) claims and adopts legacy files.
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: bucketA,
        ),
        2,
      );
      expect(prefs.legacyFlightsClaimantBucket(), bucketA);
      final moved = await LocalFlightMigration.adoptClaimedLegacyFlights(
        store: store,
        prefs: prefs,
        accountBucket: bucketA,
      );
      expect(moved, 2);
      expect(prefs.legacyFlightsResolved(), isTrue);

      // Reopen BOTH FileLocalFlightStore and PreferencesStore from disk.
      final reopenedStore = FileLocalFlightStore(
        directoryProvider: () async => tempDir,
      );
      final reopenedPrefs = await PreferencesStore.open();

      expect(reopenedPrefs.legacyFlightsResolved(), isTrue);
      expect(reopenedPrefs.legacyFlightsClaimantBucket(), bucketA);
      expect(await reopenedStore.countLegacyFlights(), 0);
      expect(
        (await reopenedStore.listFlights(bucket: bucketA)).map((f) => f.id).toList(),
        ['legacy_2', 'legacy_1'],
      );
      expect(await reopenedStore.listFlights(bucket: bucketB), isEmpty);
      expect(
        await reopenedStore.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );

      // Even if a stray file appears in legacy/ after reopen, resolved marker blocks any offer.
      final legacyDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}local_flights${Platform.pathSeparator}legacy',
      );
      await legacyDir.create(recursive: true);
      await File('${legacyDir.path}${Platform.pathSeparator}stray.json')
          .writeAsString(jsonEncode(sampleFlight('stray', 'CC-STR', 9000).toJson()));
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketA,
        ),
        0,
      );
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: LocalFlightStore.guestBucket,
        ),
        0,
      );
    });

    test('delete on disk: removes legacy files and legacy/ dir permanently, marker persists across reopen', () async {
      final tempDir = await seedLegacyRootDir();
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final store = FileLocalFlightStore(directoryProvider: () async => tempDir);

      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: bucketA,
        ),
        2,
      );
      final deleted = await LocalFlightMigration.deleteClaimedLegacyFlights(
        store: store,
        prefs: prefs,
        accountBucket: bucketA,
      );
      expect(deleted, 2);

      final legacyDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}local_flights${Platform.pathSeparator}legacy',
      );
      expect(await legacyDir.exists(), isFalse);
      expect(await store.listFlights(bucket: bucketA), isEmpty);
      expect(await store.listFlights(bucket: LocalFlightStore.guestBucket), isEmpty);

      final reopenedStore = FileLocalFlightStore(
        directoryProvider: () async => tempDir,
      );
      final reopenedPrefs = await PreferencesStore.open();
      expect(reopenedPrefs.legacyFlightsResolved(), isTrue);
      expect(await reopenedStore.countLegacyFlights(), 0);
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketB,
        ),
        0,
      );
    });

    test('dismiss on disk: remains claimed exclusively by first account across reopen', () async {
      final tempDir = await seedLegacyRootDir();
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final store = FileLocalFlightStore(directoryProvider: () async => tempDir);

      // Account A sees them (claims them) and dismisses without deciding.
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: bucketA,
        ),
        2,
      );

      // Reopen store & prefs: guest and Account B see nothing; Account B cannot adopt or delete.
      final reopenedStore = FileLocalFlightStore(
        directoryProvider: () async => tempDir,
      );
      final reopenedPrefs = await PreferencesStore.open();
      expect(reopenedPrefs.legacyFlightsClaimantBucket(), bucketA);
      expect(reopenedPrefs.legacyFlightsResolved(), isFalse);
      expect(
        await reopenedStore.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(
        await LocalFlightMigration.adoptClaimedLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(
        await LocalFlightMigration.deleteClaimedLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(await reopenedStore.countLegacyFlights(), 2);

      // Account A returns -> still offered them!
      expect(
        await LocalFlightMigration.claimOrCheckLegacyFlights(
          store: reopenedStore,
          prefs: reopenedPrefs,
          accountBucket: bucketA,
        ),
        2,
      );
    });
  });

  group('M-28: legacy local flights end-to-end UI isolation, adopt-once, delete & dismiss', () {
    final pilotA = PilotProfile(
      id: 'pilot-alpha-123',
      name: 'Ana',
      email: 'ana@club.cl',
      status: 'approved',
      role: 'pilot',
    );
    final pilotB = PilotProfile(
      id: 'pilot-bravo-456',
      name: 'Beto',
      email: 'beto@club.cl',
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

    InMemoryLocalFlightStore seedLegacyStore() => InMemoryLocalFlightStore(
          initialLegacy: [
            sampleFlight('legacy_1', 'CC-OLD', 5000),
            sampleFlight('legacy_2', 'CC-TWO', 6000),
          ],
        );

    FlightVisClient makeSwitchableClient(PilotProfile Function() activePilot) {
      return FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            final p = activePilot();
            return http.Response(
              jsonEncode({
                'email_verified': true,
                'pilot': {
                  'id': p.id,
                  'name': p.name,
                  'email': p.email,
                  'status': p.status,
                  'role': p.role,
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
    }

    FlightPermissionsClient allGrantedPerms() => _FakePermissions(
          status: const FlightPermissionStatus(
            fineLocationGranted: true,
            backgroundLocationGranted: true,
            notificationsGranted: true,
            batteryUnrestricted: true,
          ),
        );

    testWidgets('guest isolation: legacy files invisible to guest before AND after a sign-in', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _FakeSecure();
      final store = seedLegacyStore();
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: makeSwitchableClient(() => pilotA),
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
          permissions: allGrantedPerms(),
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Before any sign-in: guest sees 0 flights, no dialog, no banner.
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsNothing);
      expect(find.text('Sin vuelos guardados'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.byKey(FlightVisTestKeys.localFlightsGuestBanner), findsNothing);
      expect(find.text('CC-OLD'), findsNothing);
      expect(find.text('CC-TWO'), findsNothing);
      expect(
        find.text('Todavía no tienes vuelos guardados en este teléfono.'),
        findsOneWidget,
      );
      expect(prefs.legacyFlightsClaimantBucket(), isNull);
      expect(prefs.legacyFlightsResolved(), isFalse);

      // Navigate back to Hub via the AppBar BackButton (localized es-CL tooltip is "Atrás", not "Back").
      expect(find.byKey(FlightVisTestKeys.localFlightsListScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);

      // Pilot A signs in, dismisses without deciding (files stay in legacy/), then logs out.
      await secure.writeSessionId('sess-ana');
      final loginFuture = flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await loginFuture;

      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      // After sign-in + logout (with unresolved legacy files still present): guest STILL sees nothing.
      expect(await store.countLegacyFlights(), 2);
      expect(find.text('Sin vuelos guardados'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.text('CC-OLD'), findsNothing);
      expect(find.text('CC-TWO'), findsNothing);
      expect(
        find.text('Todavía no tienes vuelos guardados en este teléfono.'),
        findsOneWidget,
      );
    });

    testWidgets('adopt-once: first account adopts, second account and guest see nothing, marker persists across prefs reopen', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _FakeSecure();
      final store = seedLegacyStore();
      var currentPilot = pilotA;
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: makeSwitchableClient(() => currentPilot),
      );

      await tester.pumpWidget(
        FlightVisApp(
          key: const ValueKey('app-session-1'),
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _FakeTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: allGrantedPerms(),
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // First account (Pilot A) signs in and adopts legacy flights.
      await secure.writeSessionId('sess-ana');
      final loginA = flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);
      expect(
        find.text('Tienes 2 vuelos guardados de una versión anterior.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsLegacyAdopt));
      await tester.pumpAndSettle();
      await loginA;

      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      final bucketB = LocalFlightStore.bucketForPilot(pilotB);
      expect(
        (await store.listFlights(bucket: bucketA)).map((f) => f.id).toList(),
        ['legacy_2', 'legacy_1'],
      );
      expect(await store.countLegacyFlights(), 0);
      expect(prefs.legacyFlightsResolved(), isTrue);
      expect(prefs.legacyFlightsClaimantBucket(), bucketA);

      // Reopen PreferencesStore from scratch and verify marker persists.
      final reopenedPrefs = await PreferencesStore.open();
      expect(reopenedPrefs.legacyFlightsResolved(), isTrue);
      expect(reopenedPrefs.legacyFlightsClaimantBucket(), bucketA);
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );

      // Logout Pilot A -> Guest sees nothing.
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.text('CC-OLD'), findsNothing);
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);

      // Restart app with reopened prefs and sign in as Pilot B -> sees nothing.
      currentPilot = pilotB;
      final repo2 = AppRepository(
        secure: secure,
        prefs: reopenedPrefs,
        client: makeSwitchableClient(() => currentPilot),
      );
      await tester.pumpWidget(
        FlightVisApp(
          key: const ValueKey('app-session-2'),
          repo: repo2,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _FakeTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: allGrantedPerms(),
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      await secure.writeSessionId('sess-beto');
      await flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsNothing);
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.text('CC-OLD'), findsNothing);
      expect(await store.listFlights(bucket: bucketB), isEmpty);
    });

    testWidgets('delete: first account deletes with confirmation, files are gone, nobody offered later', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _FakeSecure();
      final store = seedLegacyStore();
      var currentPilot = pilotA;
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: makeSwitchableClient(() => currentPilot),
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
          permissions: allGrantedPerms(),
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      await secure.writeSessionId('sess-ana');
      final loginA = flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();

      // Tap Eliminar -> confirmation dialog appears. Cancel keeps files intact.
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsLegacyDelete));
      await tester.pumpAndSettle();
      expect(
        find.byKey(FlightVisTestKeys.localFlightsLegacyDeleteConfirmDialog),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      // Still intact and legacy choice dialog is back.
      expect(await store.countLegacyFlights(), 2);
      expect(prefs.legacyFlightsResolved(), isFalse);
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);

      // Tap Eliminar again and confirm -> files deleted permanently.
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsLegacyDelete));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(FlightVisTestKeys.localFlightsLegacyDeleteConfirm),
      );
      await tester.pumpAndSettle();
      await loginA;

      expect(await store.countLegacyFlights(), 0);
      expect(
        await store.listFlights(bucket: LocalFlightStore.bucketForPilot(pilotA)),
        isEmpty,
      );
      expect(
        await store.listFlights(bucket: LocalFlightStore.guestBucket),
        isEmpty,
      );
      expect(prefs.legacyFlightsResolved(), isTrue);

      // Nobody (Guest, Pilot B, Pilot A) is offered anything later.
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      currentPilot = pilotB;
      await secure.writeSessionId('sess-beto');
      await flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsNothing);
      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
    });

    testWidgets('dismiss: keeps legacy files claimed exclusively by the first account', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _FakeSecure();
      final store = seedLegacyStore();
      var currentPilot = pilotA;
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: makeSwitchableClient(() => currentPilot),
      );
      final bucketA = LocalFlightStore.bucketForPilot(pilotA);
      final bucketB = LocalFlightStore.bucketForPilot(pilotB);

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _FakeTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: allGrantedPerms(),
          localFlightStore: store,
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // 1. Pilot A signs in and dismisses dialog without deciding (barrier tap).
      await secure.writeSessionId('sess-ana');
      final loginA1 = flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await loginA1;

      expect(prefs.legacyFlightsClaimantBucket(), bucketA);
      expect(prefs.legacyFlightsResolved(), isFalse);
      expect(await store.countLegacyFlights(), 2);

      // 2. Pilot A logs out -> Pilot B signs in: Pilot B sees NOTHING.
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      currentPilot = pilotB;
      await secure.writeSessionId('sess-beto');
      await flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsNothing);

      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsListScreen), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.text('CC-OLD'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);

      // Programmatic guard also blocks Pilot B from adopting or deleting Pilot A's claim.
      expect(
        await LocalFlightMigration.adoptClaimedLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(
        await LocalFlightMigration.deleteClaimedLegacyFlights(
          store: store,
          prefs: prefs,
          accountBucket: bucketB,
        ),
        0,
      );
      expect(await store.countLegacyFlights(), 2);

      // 3. Pilot B logs out -> Pilot A signs back in -> Pilot A IS offered them again!
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      currentPilot = pilotA;
      await secure.writeSessionId('sess-ana-2');
      final loginA2 = flightVisAppOnLoggedInTestHook!();
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyDialog), findsOneWidget);

      // Dismiss dialog again, then adopt via the legacy banner in "Mis vuelos locales".
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await loginA2;

      await tester.tap(find.byKey(FlightVisTestKeys.hubLocalFlights));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.localFlightsLegacyAdopt));
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.localFlightsLegacyBanner), findsNothing);
      expect(find.text('CC-OLD'), findsOneWidget);
      expect(find.text('CC-TWO'), findsOneWidget);
      expect(prefs.legacyFlightsResolved(), isTrue);
      expect(await store.countLegacyFlights(), 0);
    });
  });
}
