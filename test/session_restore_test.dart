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
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

import 'helpers/fake_tile_provider.dart';

class _FakeTracker extends Fake implements TraccarClientSdk {
  bool started = true;
  int stopCalls = 0;
  int startCalls = 0;

  @override
  Future<void> init(Config config) async {}

  @override
  Future<void> setConfig(Config config) async {}

  @override
  Future<void> start() async {
    startCalls++;
    started = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    started = false;
  }

  @override
  Future<bool> isTracking() async => started;

  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

class _GrantedPermissions extends FlightPermissionsClient {
  @override
  Future<FlightPermissionStatus> check() async => const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );

  @override
  Future<bool> requestFineLocation() async => true;
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

class _MemorySecure extends SecureStore {
  _MemorySecure({this.sessionId, this.deviceToken});

  String? sessionId;
  String? deviceToken;

  @override
  Future<String?> readDeviceToken() async => deviceToken;
  @override
  Future<String?> readSessionId() async => sessionId;
  @override
  Future<void> writeDeviceToken(String token) async => deviceToken = token.trim();
  @override
  Future<void> writeSessionId(String id) async => sessionId = id.trim();
  @override
  Future<void> clearDeviceToken() async => deviceToken = null;
  @override
  Future<void> clearSessionId() async => sessionId = null;
  @override
  Future<void> clearAll() async {
    deviceToken = null;
    sessionId = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  const trackingChannel = MethodChannel('cl.heavenly.flightvis/tracking');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, null);
  });

  group('F3: meProfile() restore error handling', () {
    testWidgets('401 clears stale session id, keeps device token, and shows visible session-expired reason', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      await prefs.setCachedPilotProfile(
        PilotProfile(
          id: 'p1',
          name: 'Pablo',
          email: 'pablo@club.cl',
          status: 'approved',
          role: 'pilot',
        ),
      );
      final secure = _MemorySecure(
        sessionId: 'expired-session-123',
        deviceToken: 'tok_keep_me_0123456789abcdef0123456789',
      );
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final fakeTracker = _FakeTracker()..started = true;

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: fakeTracker,
            fixSource: InMemoryLocalFixSource(),
          ),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Session cleared and tracker stopped; device token preserved.
      expect(fakeTracker.stopCalls, greaterThanOrEqualTo(1));
      expect(fakeTracker.started, isFalse);
      expect(await secure.readSessionId(), isNull);
      expect(client.sessionId, isNull);
      expect(
        await secure.readDeviceToken(),
        'tok_keep_me_0123456789abcdef0123456789',
      );
      expect(prefs.cachedPilotProfile(), isNull);

      // Visible reason on signed-out hub.
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsOneWidget);
      expect(find.text('Tu sesión expiró. Inicia sesión de nuevo.'), findsOneWidget);
    });

    testWidgets('network error keeps session & cached pilot profile signed in and retries on resume', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      await prefs.setCachedPilotProfile(
        PilotProfile(
          id: 'p1',
          name: 'Pablo Cached',
          email: 'pablo@club.cl',
          status: 'approved',
          role: 'pilot',
        ),
      );
      final secure = _MemorySecure(
        sessionId: 'valid-session-offline',
        deviceToken: 'tok_keep_me_0123456789abcdef0123456789',
      );
      var meCalls = 0;
      var online = false;

      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            meCalls++;
            if (!online) {
              throw const SocketException('Network unreachable');
            }
            return http.Response(
              jsonEncode({
                'clubTrailMinutesDefault': 10,
                'pilot': {
                  'id': 'p1',
                  'name': 'Pablo Online',
                  'email': 'pablo@club.cl',
                  'status': 'approved',
                  'role': 'pilot',
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
          profileRetryDelay: const Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();

      // Still signed in with cached profile; session NOT cleared!
      expect(meCalls, 1);
      expect(await secure.readSessionId(), 'valid-session-offline');
      expect(client.sessionId, 'valid-session-offline');
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsNothing);
      expect(find.textContaining('Pablo Cached'), findsOneWidget);

      // Network recovers -> resume triggers retry and updates to live profile.
      online = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(meCalls, greaterThanOrEqualTo(2));
      expect(find.textContaining('Pablo Online'), findsOneWidget);
      expect(prefs.cachedPilotProfile()?.name, 'Pablo Online');
    });
  });

  group('M-24: session end stops tracking & club unavailable distinction', () {
    testWidgets('logout stops tracking and clears activeFlightId and check-in', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final futureMs = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.checkinExpiresAtKey: futureMs,
        PreferencesStore.activeClubSlugKey: 'demo-club',
        PreferencesStore.activeClubNameKey: 'Club Demo',
      });
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecure(
        sessionId: 'active-sess',
        deviceToken: 'tok_keep_me_0123456789abcdef0123456789',
      );
      var logoutCalls = 0;
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(
              jsonEncode({
                'email_verified': true,
                'pilot': {
                  'id': 'p1',
                  'name': 'Pablo',
                  'email': 'pablo@club.cl',
                  'status': 'approved',
                  'role': 'pilot',
                },
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.clubLogout) {
            logoutCalls++;
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final fakeTracker = _FakeTracker()..started = true;
      final trackingService = TrackingService(
        tracker: fakeTracker,
        fixSource: InMemoryLocalFixSource(),
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: trackingService,
          permissions: _GrantedPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Simulate an active flight & running tracker before tapping logout.
      await prefs.setActiveFlightId('flt-active-logout');
      fakeTracker.started = true;
      final stopsBeforeLogout = fakeTracker.stopCalls;

      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      expect(logoutCalls, 1);
      expect(fakeTracker.stopCalls, greaterThan(stopsBeforeLogout));
      expect(fakeTracker.started, isFalse);
      expect(prefs.activeFlightId(), isNull);
      expect(prefs.checkinExpiresAtMs(), isNull);
      expect(prefs.activeClubSlug(), isNull);
      expect(prefs.activeClubName(), isNull);
      expect(client.clubSlug, isNull);
      expect(await secure.readSessionId(), isNull);
      expect(client.sessionId, isNull);
      expect(prefs.cachedPilotProfile(), isNull);
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsNothing);
    });

    testWidgets('200 pilot:null expiry stops tracking and clears activeFlightId, check-in, and session', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final futureMs = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.activeFlightIdKey: 'flt-stale-1',
        PreferencesStore.checkinExpiresAtKey: futureMs,
        PreferencesStore.activeClubSlugKey: 'demo-club',
        PreferencesStore.activeClubNameKey: 'Club Demo',
      });
      final prefs = await PreferencesStore.open();
      await prefs.setCachedPilotProfile(
        PilotProfile(
          id: 'p1',
          name: 'Pablo',
          email: 'pablo@club.cl',
          status: 'approved',
          role: 'pilot',
        ),
      );
      final secure = _MemorySecure(
        sessionId: 'stale-sess-pilot-null',
        deviceToken: 'tok_keep_me_0123456789abcdef0123456789',
      );
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(jsonEncode({'pilot': null}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final fakeTracker = _FakeTracker()..started = true;
      final trackingService = TrackingService(
        tracker: fakeTracker,
        fixSource: InMemoryLocalFixSource(),
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: trackingService,
          permissions: _GrantedPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeTracker.stopCalls, greaterThanOrEqualTo(1));
      expect(fakeTracker.started, isFalse);
      expect(prefs.activeFlightId(), isNull);
      expect(prefs.checkinExpiresAtMs(), isNull);
      expect(prefs.activeClubSlug(), isNull);
      expect(prefs.activeClubName(), isNull);
      expect(await secure.readSessionId(), isNull);
      expect(client.sessionId, isNull);
      expect(
        await secure.readDeviceToken(),
        'tok_keep_me_0123456789abcdef0123456789',
      );
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsOneWidget);
      expect(find.text('Tu sesión expiró. Inicia sesión de nuevo.'), findsOneWidget);
    });

    testWidgets('403 club unavailable shows its own message, keeps session, and disables club broadcast', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final futureMs = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.checkinExpiresAtKey: futureMs,
        PreferencesStore.activeClubSlugKey: 'demo-club',
        PreferencesStore.activeClubNameKey: 'Club Demo',
      });
      final prefs = await PreferencesStore.open();
      await prefs.setCachedPilotProfile(
        PilotProfile(
          id: 'p1',
          name: 'Pablo SuspendedClub',
          email: 'pablo@club.cl',
          status: 'approved',
          role: 'pilot',
          emailVerified: true,
        ),
      );
      final secure = _MemorySecure(
        sessionId: 'keep-me-session',
        deviceToken: 'tok_keep_me_0123456789abcdef0123456789',
      );
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(
              jsonEncode({'error': 'club unavailable'}),
              403,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final fakeTracker = _FakeTracker()..started = true;
      final trackingService = TrackingService(
        tracker: fakeTracker,
        fixSource: InMemoryLocalFixSource(),
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: trackingService,
          permissions: _GrantedPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
          profileRetryDelay: const Duration(seconds: 60),
        ),
      );
      await tester.pumpAndSettle();

      // Session and cached pilot MUST be preserved (NOT expiry).
      expect(await secure.readSessionId(), 'keep-me-session');
      expect(client.sessionId, 'keep-me-session');
      expect(prefs.cachedPilotProfile()?.name, 'Pablo SuspendedClub');
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsNothing);

      // Club-unavailable message shown and club broadcast disabled.
      expect(find.byKey(FlightVisTestKeys.hubClubUnavailableBanner), findsOneWidget);
      expect(
        find.text('Tu club no está disponible por ahora. Contacta a tu club.'),
        findsAtLeastNWidgets(1),
      );
      final detailsTile = tester.widget<ListTile>(
        find.byKey(FlightVisTestKeys.hubFlightDetails),
      );
      expect(detailsTile.enabled, isFalse);

      // Tapping Iniciar vuelo falls back to local-only dialog, NOT club broadcast.
      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.localFlightStartDialog), findsOneWidget);
    });

    testWidgets('_restore with leftover activeFlightId but no session refuses to resume and stops tracker', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final futureMs = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.activeFlightIdKey: 'flt-leftover-no-session',
        PreferencesStore.checkinExpiresAtKey: futureMs,
      });
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecure(
        sessionId: null,
        deviceToken: 'tok_leftover_0123456789abcdef0123456789',
      );
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final fakeTracker = _FakeTracker()..started = true;
      final trackingService = TrackingService(
        tracker: fakeTracker,
        fixSource: InMemoryLocalFixSource(),
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: trackingService,
          permissions: _GrantedPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeTracker.stopCalls, greaterThanOrEqualTo(1));
      expect(fakeTracker.started, isFalse);
      expect(prefs.activeFlightId(), isNull);
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
    });
  });
}
