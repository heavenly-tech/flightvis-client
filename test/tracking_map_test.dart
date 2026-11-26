import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/map/map_tile_config.dart';
import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/widgets/tracking_map_card.dart';

import 'helpers/fake_tile_provider.dart';

const _deviceToken = '01234567890123456789012345678901';
const _flightUuid = '550e8400-e29b-41d4-a716-446655440000';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => _deviceToken;
  @override
  Future<String?> readSessionId() async => 'sess-map';
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

class _FakeTracker extends Fake implements TraccarClientSdk {
  bool started = false;
  @override
  Future<void> init(Config config) async {}
  @override
  Future<void> setConfig(Config config) async {}
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => started = false;
  @override
  Future<bool> isTracking() async => started;
  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

Map<String, dynamic> _clubFlightJson({String tail = 'CC-CLB'}) => {
      'flightId': 'flt-club-1',
      'tail': tail,
      'layer': 'club',
      'trailMinutes': 5,
      'points': [
        [1700000000000, -33.450, -70.542, 910.0],
        [1700000060000, -33.448, -70.539, 930.0],
        [1700000120000, -33.446, -70.536, 950.0],
      ],
    };

Map<String, dynamic> _publicFlightJson({String tail = 'CC-PUB'}) => {
      'flightId': 'flt-pub-1',
      'tail': tail,
      'layer': 'public',
      'trailMinutes': 5,
      'points': [
        [1700000000000, -33.464, -70.560, 1020.0],
        [1700000060000, -33.462, -70.557, null],
        [1700000120000, -33.460, -70.554, 1060.0],
      ],
    };

List<LocalFix> _sampleOwnFixes() {
  const baseMs = 1_700_000_000_000;
  const minMs = 60 * 1000;
  // 21 fixes covering 0..20 minutes.
  return [
    for (var m = 0; m <= 20; m++)
      LocalFix(
        timeMs: baseMs + m * minMs,
        latitude: -33.465 + m * 0.0005,
        longitude: -70.555 + m * 0.0004,
        altitude: 900.0 + m * 5,
        bearing: 45.0,
      ),
  ];
}

int _totalPolylinePoints(WidgetTester tester) {
  final finder = find.byType(PolylineLayer);
  if (finder.evaluate().isEmpty) return 0;
  final layer = tester.widget<PolylineLayer>(finder);
  var count = 0;
  for (final poly in layer.polylines) {
    count += poly.points.length;
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('Layer toggles, persistence, request scoping, and lifecycle polling', () {
    testWidgets('defaults to Mío/Club ON and Público OFF, and persists across rebuild', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: _deviceToken,
        httpClient: http_testing.MockClient(
          (_) async => http.Response(jsonEncode({'flights': []}), 200),
        ),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      Widget buildWidget() => PilotAppShell(
            locale: const Locale('es', 'CL'),
            home: Scaffold(
              body: TrackingMapCard(
                client: client,
                prefs: prefs,
                ownTail: 'CC-ABC',
                trailMinutesOverride: 5,
                clubDefaultMinutes: 5,
                fixSource: fixSource,
                tileProvider: FakeTileProvider(),
              ),
            ),
          );

      await tester.pumpWidget(buildWidget());
      await tester.pumpAndSettle();

      FilterChip chip(Key key) => tester.widget<FilterChip>(
            find.descendant(of: find.byKey(key), matching: find.byType(FilterChip)),
          );

      expect(chip(FlightVisTestKeys.mapLayerMine).selected, isTrue);
      expect(chip(FlightVisTestKeys.mapLayerClub).selected, isTrue);
      expect(chip(FlightVisTestKeys.mapLayerPublic).selected, isFalse);

      // Toggle Mío OFF and Público ON.
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerMine));
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerPublic));
      await tester.pumpAndSettle();

      expect(prefs.mapLayerOwn(), isFalse);
      expect(prefs.mapLayerClub(), isTrue);
      expect(prefs.mapLayerPublic(), isTrue);

      // Unmount and rebuild a brand-new widget tree backed by a fresh PreferencesStore.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final reloadedPrefs = await PreferencesStore.open();
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrackingMapCard(
              client: client,
              prefs: reloadedPrefs,
              ownTail: 'CC-ABC',
              trailMinutesOverride: 5,
              clubDefaultMinutes: 5,
              fixSource: fixSource,
              tileProvider: FakeTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(chip(FlightVisTestKeys.mapLayerMine).selected, isFalse);
      expect(chip(FlightVisTestKeys.mapLayerClub).selected, isTrue);
      expect(chip(FlightVisTestKeys.mapLayerPublic).selected, isTrue);
    });

    testWidgets('request layers strictly follow toggles and both off makes zero requests', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final seenLayers = <String?>[];
      final seenIfNoneMatch = <String?>[];
      var failNext = false;

      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        deviceToken: _deviceToken,
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path != '/api/me/live-trails') {
            return http.Response('{}', 404);
          }
          final layers = request.url.queryParameters['layers'];
          seenLayers.add(layers);
          seenIfNoneMatch.add(request.headers['If-None-Match']);
          if (failNext) {
            return http.Response(jsonEncode({'error': 'server error'}), 500);
          }
          final etag = 'W/"tag-$layers"';
          if (request.headers['If-None-Match'] == etag) {
            return http.Response('', 304, headers: {'etag': etag});
          }
          final flights = <Map<String, dynamic>>[
            if (layers == 'club' || layers == 'club,public') _clubFlightJson(),
            if (layers == 'public' || layers == 'club,public') _publicFlightJson(),
          ];
          return http.Response(
            jsonEncode({'flights': flights}),
            200,
            headers: {'etag': etag},
          );
        }),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrackingMapCard(
              client: client,
              prefs: prefs,
              ownTail: 'CC-ABC',
              trailMinutesOverride: 5,
              clubDefaultMinutes: 5,
              fixSource: fixSource,
              tileProvider: FakeTileProvider(),
              pollInterval: const Duration(seconds: 5),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Default: Club ON, Público OFF -> ONLY requests layers=club, never public.
      expect(seenLayers, ['club']);
      expect(find.text('CC-CLB'), findsOneWidget);
      expect(find.text('CC-PUB'), findsNothing);

      // Next poll after 5s sends If-None-Match and receives 304 -> preserves CC-CLB.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(seenLayers, ['club', 'club']);
      expect(seenIfNoneMatch.last, 'W/"tag-club"');
      expect(find.text('CC-CLB'), findsOneWidget);

      // Transient error keeps last data and shows no SnackBar.
      failNext = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('CC-CLB'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      failNext = false;

      // Enable Público -> requests layers=club,public and shows CC-PUB.
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerPublic));
      await tester.pumpAndSettle();
      expect(seenLayers.last, 'club,public');
      expect(find.text('CC-CLB'), findsOneWidget);
      expect(find.text('CC-PUB'), findsOneWidget);

      // Disable Club -> requests layers=public and removes CC-CLB.
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerClub));
      await tester.pumpAndSettle();
      expect(seenLayers.last, 'public');
      expect(find.text('CC-CLB'), findsNothing);
      expect(find.text('CC-PUB'), findsOneWidget);

      // Disable Público too (both Club and Público OFF) -> NO request at all.
      final callsBeforeBothOff = seenLayers.length;
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerPublic));
      await tester.pumpAndSettle();
      expect(find.text('CC-PUB'), findsNothing);

      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(seenLayers.length, callsBeforeBothOff);
    });

    testWidgets('pauses remote polling when AppLifecycleState goes paused and resumes on resumed', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      var pollCount = 0;

      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: _deviceToken,
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == '/api/me/live-trails') {
            pollCount++;
            return http.Response(
              jsonEncode({'flights': [_clubFlightJson()]}),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrackingMapCard(
              client: client,
              prefs: prefs,
              ownTail: 'CC-ABC',
              trailMinutesOverride: 5,
              clubDefaultMinutes: 5,
              fixSource: fixSource,
              tileProvider: FakeTileProvider(),
              pollInterval: const Duration(seconds: 5),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(pollCount, 1);

      // Background the app -> polling stops completely.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(pollCount, 1);

      // Resume -> immediately polls again and resumes periodic schedule.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(pollCount, 2);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(pollCount, 3);
    });
  });

  group('Own trail live re-windowing, controls, OSM policy, and 360x640 layout', () {
    testWidgets('changing X re-windows drawn own trail immediately without own-trail server request', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: _flightUuid,
        PreferencesStore.checkinExpiresAtKey:
            DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
        PreferencesStore.clubTrailMinutesDefaultKey: 2,
        PreferencesStore.mapLayerClubKey: false,
        PreferencesStore.mapLayerPublicKey: false,
      });
      final prefs = await PreferencesStore.open();
      final liveTrailsRequests = <http.Request>[];
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: prefs.baseUrl(),
          deviceToken: _deviceToken,
          httpClient: http_testing.MockClient((request) async {
            if (request.url.path == '/api/me/live-trails') {
              liveTrailsRequests.add(request);
            }
            if (request.method == 'PATCH' &&
                request.url.path == '/api/flights/$_flightUuid/trail') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({'trailMinutes': body['trailMinutes']}),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        ),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            repo: repo,
            flightId: _flightUuid,
            tail: 'CC-ABC',
            tracking: TrackingService(tracker: _FakeTracker(), fixSource: fixSource),
            onStopped: () {},
            tileProvider: FakeTileProvider(),
            initialOwnFixes: _sampleOwnFixes(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Club default = 2 min -> 3 own points (m=18,19,20).
      final pts2Min = _totalPolylinePoints(tester);
      expect(pts2Min, greaterThanOrEqualTo(3));

      // Switch to 15 min -> immediately increases drawn polyline points.
      await tester.ensureVisible(find.byKey(FlightVisTestKeys.trailChip(15)));
      await tester.tap(find.byKey(FlightVisTestKeys.trailChip(15)));
      await tester.pumpAndSettle();
      final pts15Min = _totalPolylinePoints(tester);
      expect(pts15Min, greaterThan(pts2Min));

      // Switch to Off (0) -> polyline disappears, own marker stays visible!
      await tester.ensureVisible(find.byKey(FlightVisTestKeys.trailChip(0)));
      await tester.tap(find.byKey(FlightVisTestKeys.trailChip(0)));
      await tester.pumpAndSettle();
      expect(_totalPolylinePoints(tester), 0);
      expect(find.text('CC-ABC'), findsOneWidget);

      // Own trail never triggers /api/me/live-trails.
      expect(liveTrailsRequests, isEmpty);
    });

    testWidgets('follow toggle disables on pan, recenter re-enables, zoom +/- work, and OSM policy enforced', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.mapLayerClubKey: false,
        PreferencesStore.mapLayerPublicKey: false,
      });
      final prefs = await PreferencesStore.open();
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: _deviceToken,
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrackingMapCard(
              client: client,
              prefs: prefs,
              ownTail: 'CC-ABC',
              trailMinutesOverride: 5,
              clubDefaultMinutes: 5,
              fixSource: fixSource,
              tileProvider: FakeTileProvider(),
              initialOwnFixes: _sampleOwnFixes(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify OSM TileLayer configuration & visible attribution.
      final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
      expect(tileLayer.urlTemplate, kOsmTileConfig.urlTemplate);
      expect(tileLayer.urlTemplate, 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
      expect(tileLayer.panBuffer, 0);
      expect(
        tileLayer.tileProvider.headers['User-Agent'],
        contains('cl.heavenly.flightvis'),
      );
      expect(find.byType(SimpleAttributionWidget), findsOneWidget);
      expect(find.text('OpenStreetMap contributors'), findsOneWidget);

      // Auto-follow starts ON.
      expect(
        find.descendant(
          of: find.byKey(FlightVisTestKeys.mapFollowToggle),
          matching: find.byIcon(Icons.my_location),
        ),
        findsOneWidget,
      );

      // Panning disables follow.
      await tester.drag(find.byType(FlutterMap), const Offset(80, 40));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(FlightVisTestKeys.mapFollowToggle),
          matching: find.byIcon(Icons.location_searching),
        ),
        findsOneWidget,
      );

      // Tapping recenter re-enables follow.
      await tester.tap(find.byKey(FlightVisTestKeys.mapFollowToggle));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(FlightVisTestKeys.mapFollowToggle),
          matching: find.byIcon(Icons.my_location),
        ),
        findsOneWidget,
      );

      // Zoom +/- buttons respond cleanly without error.
      await tester.tap(find.byKey(FlightVisTestKeys.mapZoomIn));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.mapZoomOut));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('throttles rapid >1Hz own fix bursts to at most 1Hz redraws and buffers while paused', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.mapLayerClubKey: false,
        PreferencesStore.mapLayerPublicKey: false,
      });
      final prefs = await PreferencesStore.open();
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        deviceToken: _deviceToken,
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      );
      final fixSource = InMemoryLocalFixSource();
      addTearDown(fixSource.dispose);

      var currentTime = DateTime.utc(2026, 11, 26, 12, 0, 0);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: Scaffold(
            body: TrackingMapCard(
              client: client,
              prefs: prefs,
              ownTail: 'CC-ABC',
              trailMinutesOverride: 5,
              clubDefaultMinutes: 5,
              fixSource: fixSource,
              tileProvider: FakeTileProvider(),
              clock: () => currentTime,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially waiting for GPS fix.
      expect(find.text('Esperando señal GPS…'), findsOneWidget);

      // First fix arrives -> immediately draws own marker.
      const baseMs = 1_700_000_000_000;
      fixSource.emit(
        const LocalFix(timeMs: baseMs, latitude: -33.456, longitude: -70.548),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Esperando señal GPS…'), findsNothing);
      expect(find.text('CC-ABC'), findsOneWidget);
      expect(_totalPolylinePoints(tester), 0);

      // Burst of 2 rapid fixes within 400ms -> throttled, does not redraw immediately.
      currentTime = currentTime.add(const Duration(milliseconds: 200));
      fixSource.emit(
        const LocalFix(timeMs: baseMs + 200, latitude: -33.455, longitude: -70.547),
      );
      currentTime = currentTime.add(const Duration(milliseconds: 200));
      fixSource.emit(
        const LocalFix(timeMs: baseMs + 400, latitude: -33.454, longitude: -70.546),
      );
      await tester.pump();
      await tester.pump();
      expect(_totalPolylinePoints(tester), 0);

      // After throttle window (~1s total) elapses -> coalesced redraw renders all fixes!
      currentTime = currentTime.add(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(_totalPolylinePoints(tester), greaterThanOrEqualTo(3));

      // Pause lifecycle -> new fixes buffered in source are recovered on resume.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final ptsBeforePause = _totalPolylinePoints(tester);
      fixSource.emit(
        const LocalFix(timeMs: baseMs + 10000, latitude: -33.451, longitude: -70.542),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(_totalPolylinePoints(tester), ptsBeforePause);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_totalPolylinePoints(tester), greaterThan(ptsBeforePause));
    });

    testWidgets('at 360x640 Stop button stays visible and never covered by the map', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: _flightUuid,
        PreferencesStore.checkinExpiresAtKey:
            DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
        PreferencesStore.clubTrailMinutesDefaultKey: 5,
      });
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: prefs.baseUrl(),
          deviceToken: _deviceToken,
          httpClient: http_testing.MockClient((request) async {
            if (request.url.path == '/api/me/live-trails') {
              return http.Response(jsonEncode({'flights': [_clubFlightJson()]}), 200);
            }
            return http.Response('{}', 200);
          }),
        ),
      );
      final fixSource = InMemoryLocalFixSource(initialFixes: _sampleOwnFixes());
      addTearDown(fixSource.dispose);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            repo: repo,
            flightId: _flightUuid,
            tail: 'CC-ABC',
            tracking: TrackingService(tracker: _FakeTracker(), fixSource: fixSource),
            onStopped: () {},
            tileProvider: FakeTileProvider(),
            initialOwnFixes: _sampleOwnFixes(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final mapFinder = find.byKey(FlightVisTestKeys.trackingMap);
      final stopFinder = find.byKey(FlightVisTestKeys.trackingStop);
      expect(mapFinder, findsOneWidget);
      expect(stopFinder, findsOneWidget);

      final mapRect = tester.getRect(mapFinder);
      final stopRect = tester.getRect(stopFinder);

      // Stop button is fully inside the 360x640 viewport without scrolling,
      // and strictly below the map with zero overlap.
      expect(stopRect.top, greaterThanOrEqualTo(mapRect.bottom));
      expect(stopRect.bottom, lessThanOrEqualTo(640.0));
      expect(stopRect.left, greaterThanOrEqualTo(0.0));
      expect(stopRect.right, lessThanOrEqualTo(360.0));
      expect(mapRect.height, greaterThanOrEqualTo(170.0));
    });
  });
}
