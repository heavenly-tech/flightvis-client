import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

import 'helpers/fake_tile_provider.dart';

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

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Session cleared; device token preserved.
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
}
