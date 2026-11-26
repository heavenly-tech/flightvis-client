import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:flight_vis/screens/checkin_screen.dart';
import 'package:flight_vis/screens/login_screen.dart';
import 'package:flight_vis/screens/pairing_screen.dart';
import 'package:flight_vis/screens/permissions_onboarding_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

import 'helpers/fake_tile_provider.dart';

class _FakeSecure extends SecureStore {
  _FakeSecure({this.deviceToken});
  final String? deviceToken;
  @override
  Future<String?> readDeviceToken() async => deviceToken;
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

List<LocalFix> _demoOwnFixes() {
  const baseMs = 1_700_000_000_000;
  // Curved northbound-to-northeast own track cleanly framed in map viewport.
  const coords = <(double, double)>[
    (-33.4618, -70.5562),
    (-33.4606, -70.5554),
    (-33.4594, -70.5540),
    (-33.4582, -70.5522),
    (-33.4572, -70.5504),
    (-33.4563, -70.5488),
    (-33.4555, -70.5474),
    (-33.4548, -70.5462),
    (-33.4542, -70.5451),
    (-33.4537, -70.5442),
  ];
  return [
    for (var i = 0; i < coords.length; i++)
      LocalFix(
        timeMs: baseMs + i * 60 * 1000,
        latitude: coords[i].$1,
        longitude: coords[i].$2,
        altitude: 900.0 + i * 25,
        bearing: 42.0,
      ),
  ];
}

List<LiveTrailFlight> _demoRemoteFlights() {
  const baseMs = 1_700_000_000_000;
  return [
    LiveTrailFlight(
      flightId: 'flt-club-demo',
      tail: 'CC-CLB',
      layer: 'club',
      trailMinutes: 5,
      points: [
        const LiveTrailPoint(timeMs: baseMs + 120000, latitude: -33.4445, longitude: -70.5565, altitude: 1020),
        const LiveTrailPoint(timeMs: baseMs + 240000, latitude: -33.4455, longitude: -70.5520, altitude: 1040),
        const LiveTrailPoint(timeMs: baseMs + 360000, latitude: -33.4465, longitude: -70.5472, altitude: 1055),
        const LiveTrailPoint(timeMs: baseMs + 480000, latitude: -33.4475, longitude: -70.5425, altitude: 1070),
        const LiveTrailPoint(timeMs: baseMs + 540000, latitude: -33.4484, longitude: -70.5382, altitude: 1085),
      ],
    ),
    LiveTrailFlight(
      flightId: 'flt-pub-demo',
      tail: 'CC-PUB',
      layer: 'public',
      trailMinutes: 5,
      points: [
        const LiveTrailPoint(timeMs: baseMs + 120000, latitude: -33.4628, longitude: -70.5265, altitude: 1180),
        const LiveTrailPoint(timeMs: baseMs + 240000, latitude: -33.4618, longitude: -70.5290, altitude: 1190),
        const LiveTrailPoint(timeMs: baseMs + 360000, latitude: -33.4608, longitude: -70.5315, altitude: 1200),
        const LiveTrailPoint(timeMs: baseMs + 480000, latitude: -33.4596, longitude: -70.5338, altitude: 1210),
        const LiveTrailPoint(timeMs: baseMs + 540000, latitude: -33.4584, longitude: -70.5356, altitude: 1220),
      ],
    ),
  ];
}

Future<void> _maybeExportShot(WidgetTester tester, String fileName) async {
  final dirPath = Platform.environment['SHOTS_DIR'];
  if (dirPath == null || dirPath.trim().isEmpty) return;
  await tester.runAsync(() async {
    final element = find.byType(MaterialApp).evaluate().single;
    final image = await captureImage(element);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}/$fileName').writeAsBytesSync(data.buffer.asUint8List());
  });
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
  await tester.pumpWidget(PilotAppShell(home: home, locale: const Locale('es')));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 100));
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../docs/screenshots/$name.png'),
  );
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

  testWidgets('login golden', (tester) async {
    final repo = await _repo();
    await _golden(
      tester,
      LoginScreen(
        repo: repo,
        onLoggedIn: () {},
        onContinueAsGuest: () {},
        signupAvailabilityProbe: (_) async => true,
      ),
      '01-login-options',
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
    final repo = await _repo();
    await _golden(
      tester,
      PermissionsOnboardingScreen(repo: repo, onComplete: () {}),
      '04-permissions',
    );
  });

  testWidgets('login golden (EN sample)', (tester) async {
    final repo = await _repo();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      PilotAppShell(
        home: LoginScreen(
          repo: repo,
          onLoggedIn: () {},
          onContinueAsGuest: () {},
          signupAvailabilityProbe: (_) async => true,
        ),
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../docs/screenshots/01-login-options-en.png'),
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
      TailPickerScreen(repo: repo, onFlightStarted: (_, _) {}),
      '05-tail-picker',
    );
  });

  testWidgets('tracking active golden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _FakeSecure(),
      prefs: prefs,
      client: FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    await _golden(
      tester,
      TrackingScreen(
        repo: repo,
        flightId: 'flight-demo',
        tail: 'N12345',
        tracking: TrackingService(
          tracker: _FakeTracker(),
          fixSource: InMemoryLocalFixSource(),
        ),
        onStopped: () {},
        tileProvider: FakeTileProvider(),
        enableMapPolling: false,
      ),
      '06-tracking',
    );
  });

  testWidgets('tracking map trails golden (own + club + public)', (tester) async {
    SharedPreferences.setMockInitialValues({
      PreferencesStore.activeFlightIdKey: 'flight-demo',
      PreferencesStore.activeFlightTrailMinutesKey: 10,
      PreferencesStore.clubTrailMinutesDefaultKey: 5,
      PreferencesStore.mapLayerOwnKey: true,
      PreferencesStore.mapLayerClubKey: true,
      PreferencesStore.mapLayerPublicKey: true,
    });
    final prefs = await PreferencesStore.open();
    final repo = AppRepository(
      secure: _FakeSecure(deviceToken: '01234567890123456789012345678901'),
      prefs: prefs,
      client: FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    final fixSource = InMemoryLocalFixSource(initialFixes: _demoOwnFixes());
    addTearDown(fixSource.dispose);

    await _golden(
      tester,
      TrackingScreen(
        repo: repo,
        flightId: 'flight-demo',
        tail: 'CC-ABC',
        tracking: TrackingService(
          tracker: _FakeTracker(),
          fixSource: fixSource,
        ),
        onStopped: () {},
        tileProvider: FakeTileProvider(),
        enableMapPolling: false,
        initialOwnFixes: _demoOwnFixes(),
        initialRemoteFlights: _demoRemoteFlights(),
      ),
      '07-tracking-map-trails',
    );
    await _maybeExportShot(tester, 'tracking-map-trails-390x844.png');

    // Also capture a 360x640 small-screen shot and an open radius menu shot when SHOTS_DIR is set.
    if ((Platform.environment['SHOTS_DIR'] ?? '').trim().isNotEmpty) {
      await tester.tap(find.byKey(FlightVisTestKeys.mapPublicRadiusButton));
      await tester.pumpAndSettle();
      await _maybeExportShot(tester, 'tracking-map-radius-390x844.png');
      // Dismiss popup menu before resizing to 360x640.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pumpAndSettle();
      await _maybeExportShot(tester, 'tracking-map-trails-360x640.png');
      await tester.binding.setSurfaceSize(const Size(390, 844));
    }
  });
}