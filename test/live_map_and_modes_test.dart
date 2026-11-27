import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/live_map_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/device_location_provider.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/widgets/tracking_map_card.dart';

import 'helpers/fake_tile_provider.dart';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => '01234567890123456789012345678901';
  @override
  Future<String?> readSessionId() async => 'sess-live';
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

Map<String, dynamic> _clubFlightJson() => {
      'flightId': 'flt-club-1',
      'tail': 'CC-CLB',
      'layer': 'club',
      'trailMinutes': 5,
      'points': [
        [1700000000000, -33.450, -70.542, 910.0],
        [1700000060000, -33.448, -70.539, 930.0],
      ],
    };

Map<String, dynamic> _publicFlightJson() => {
      'flightId': 'flt-pub-1',
      'tail': 'CC-PUB',
      'layer': 'public',
      'trailMinutes': 5,
      'points': [
        [1700000000000, -33.464, -70.560, 1020.0],
        [1700000060000, -33.462, -70.557, 1040.0],
      ],
    };

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

  group('Guest live map (anonymous /api/public/live-trails)', () {
    testWidgets('opens with Público ON, Club disabled with reason, polls anonymous endpoint without auth using device location', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final seenRequests = <http.Request>[];
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'must-not-leak',
          deviceToken: 'must-not-leak',
          httpClient: http_testing.MockClient((request) async {
            seenRequests.add(request);
            if (request.url.path == FlightVisApiPaths.publicLiveTrails) {
              return http.Response(
                jsonEncode({'flights': [_publicFlightJson()]}),
                200,
              );
            }
            return http.Response('{}', 404);
          }),
        ),
      );
      final fakeLoc = FakeDeviceLocationProvider(
        location: const LocalFix(
          timeMs: 1700000000000,
          latitude: -33.456789,
          longitude: -70.548123,
        ),
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
            deviceLocationProvider: fakeLoc,
            localFlightStore: InMemoryLocalFlightStore(),
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Signed-out hub has both "Ver mapa en vivo" and "Iniciar vuelo" enabled.
      expect(find.byKey(FlightVisTestKeys.hubLiveMap), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.hubStartFlight), findsOneWidget);
      expect(find.text('Ver mapa en vivo'), findsOneWidget);
      expect(find.text('Iniciar vuelo'), findsOneWidget);

      await tester.tap(find.byKey(FlightVisTestKeys.hubLiveMap));
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.liveMapScreen), findsOneWidget);
      expect(
        find.text('Inicia sesión para ver los vuelos de tu club'),
        findsOneWidget,
      );
      final clubChip = tester.widget<FilterChip>(
        find.descendant(
          of: find.byKey(FlightVisTestKeys.mapLayerClub),
          matching: find.byType(FilterChip),
        ),
      );
      expect(clubChip.onSelected, isNull);
      expect(clubChip.selected, isFalse);

      // Polled anonymous endpoint with lat/lon/radius_km=20 and ZERO auth headers.
      expect(seenRequests, hasLength(1));
      final req = seenRequests.single;
      expect(req.url.path, '/api/public/live-trails');
      expect(req.url.queryParameters, {
        'lat': '-33.456789',
        'lon': '-70.548123',
        'radius_km': '20',
      });
      expect(req.headers.containsKey('Cookie'), isFalse);
      expect(req.headers.containsKey('Authorization'), isFalse);
      expect(find.text('CC-PUB'), findsOneWidget);
    });

    testWidgets('guest map makes ZERO requests without position and treats 404 silently with subtle status line', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final seenRequests = <http.Request>[];
      var return404 = true;
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          httpClient: http_testing.MockClient((request) async {
            seenRequests.add(request);
            if (return404) {
              return http.Response(jsonEncode({'error': 'not found'}), 404);
            }
            return http.Response(
              jsonEncode({'flights': [_publicFlightJson()]}),
              200,
            );
          }),
        ),
      );
      final fakeLoc = FakeDeviceLocationProvider(location: null);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LiveMapScreen(
            repo: repo,
            loggedIn: false,
            deviceLocationProvider: fakeLoc,
            tileProvider: FakeTileProvider(),
            mapPollInterval: const Duration(seconds: 5),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Without position: zero requests and waiting hint visible.
      expect(seenRequests, isEmpty);
      expect(find.byKey(FlightVisTestKeys.mapPublicWaitingPosition), findsOneWidget);

      // Location becomes available on 30s device location poll -> hits anonymous endpoint -> 404.
      fakeLoc.location = const LocalFix(
        timeMs: 1700000000000,
        latitude: -33.45,
        longitude: -70.55,
      );
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();

      expect(seenRequests, hasLength(1));
      expect(seenRequests.single.url.path, '/api/public/live-trails');
      expect(find.byKey(FlightVisTestKeys.mapPollStatusError), findsOneWidget);
      expect(
        find.text('Sin conexión con el servidor; reintentando…'),
        findsOneWidget,
      );
      expect(find.byKey(FlightVisTestKeys.mapSessionExpiredBanner), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      // Next 5s poll succeeds -> status line clears and flight appears.
      return404 = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.mapPollStatusError), findsNothing);
      expect(find.text('CC-PUB'), findsOneWidget);
    });
  });

  group('Signed-in no check-in map & F2 error handling', () {
    testWidgets('hub opens authenticated LiveMapScreen: club has no coords, public uses fake device location', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.mapLayerClubKey: true,
        PreferencesStore.mapLayerPublicKey: false,
      });
      final prefs = await PreferencesStore.open();
      final seenRequests = <http.Request>[];
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(
          baseUrl: 'https://example.test',
          sessionId: 'sess-ok',
          httpClient: http_testing.MockClient((request) async {
            seenRequests.add(request);
            if (request.url.path == FlightVisApiPaths.meLiveTrails) {
              final layers = request.url.queryParameters['layers'] ?? '';
              return http.Response(
                jsonEncode({
                  'flights': [
                    if (layers.contains('club')) _clubFlightJson(),
                    if (layers.contains('public')) _publicFlightJson(),
                  ],
                }),
                200,
              );
            }
            return http.Response('{}', 404);
          }),
        ),
      );
      final fakeLoc = FakeDeviceLocationProvider(
        location: const LocalFix(
          timeMs: 1700000000000,
          latitude: -33.451234,
          longitude: -70.541234,
        ),
      );
      final pilot = PilotProfile(
        id: 'p1',
        name: 'Pablo',
        email: 'pablo@club.cl',
        status: 'approved',
        role: 'pilot',
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: HomeHubScreen(
            repo: repo,
            pilot: pilot,
            onStartFlight: (_, _) {},
            onRequestLogin: () {},
            onLogout: () {},
            deviceLocationProvider: fakeLoc,
            localFlightStore: InMemoryLocalFlightStore(),
            tileProvider: FakeTileProvider(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.hubLiveMap));
      await tester.pumpAndSettle();

      // Club request has NO lat/lon/radius_km.
      expect(seenRequests, hasLength(1));
      expect(seenRequests.single.url.path, '/api/me/live-trails');
      expect(seenRequests.single.url.queryParameters, {'layers': 'club'});
      expect(find.text('CC-CLB'), findsOneWidget);

      // Toggle Público ON -> uses fake device location even though there is no local fix.
      await tester.tap(find.byKey(FlightVisTestKeys.mapLayerPublic));
      await tester.pumpAndSettle();

      expect(seenRequests, hasLength(2));
      expect(seenRequests.last.url.queryParameters['layers'], 'club,public');
      expect(seenRequests.last.url.queryParameters['lat'], '-33.451234');
      expect(seenRequests.last.url.queryParameters['lon'], '-70.541234');
      expect(seenRequests.last.url.queryParameters['radius_km'], '20');
      expect(find.text('CC-PUB'), findsOneWidget);
    });

    testWidgets('F2: 401 shows non-blocking session expired prompt with sign-in button; 500 shows subtle status line that clears on recovery', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.mapLayerClubKey: true,
        PreferencesStore.mapLayerPublicKey: false,
      });
      final prefs = await PreferencesStore.open();
      var mode = 'ok';
      var signInTriggered = 0;

      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'sess-1',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path != FlightVisApiPaths.meLiveTrails) {
            return http.Response('{}', 404);
          }
          if (mode == '401') {
            return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
          }
          if (mode == '500') {
            return http.Response(jsonEncode({'error': 'boom'}), 500);
          }
          return http.Response(
            jsonEncode({'flights': [_clubFlightJson()]}),
            200,
          );
        }),
      );
      final fixSource = InMemoryLocalFixSource();
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
              onSessionExpired: () => signInTriggered++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CC-CLB'), findsOneWidget);

      // 401 -> keeps last data, shows visible prompt + sign-in button, no SnackBar.
      mode = '401';
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('CC-CLB'), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.mapSessionExpiredBanner), findsOneWidget);
      expect(find.text('Tu sesión expiró. Inicia sesión de nuevo.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byKey(FlightVisTestKeys.mapSessionExpiredSignIn));
      await tester.pump();
      expect(signInTriggered, 1);

      // Recover -> prompt clears.
      mode = 'ok';
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.mapSessionExpiredBanner), findsNothing);

      // 500 -> keeps last data, shows subtle status line, no SnackBar.
      mode = '500';
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('CC-CLB'), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.mapPollStatusError), findsOneWidget);
      expect(
        find.text('Sin conexión con el servidor; reintentando…'),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);

      // Next success clears status line.
      mode = 'ok';
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.mapPollStatusError), findsNothing);
    });
  });
}
