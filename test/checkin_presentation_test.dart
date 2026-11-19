import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/screens/checkin_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

const _kioskToken = 'v1.club1.999999.abcdef0123456789abcdef0123456789';
const _demoSlug = 'demo-club';
const _deviceToken = '01234567890123456789012345678901';
const _sessionId = 'sess-test-1';

const _checkinSuccess = {
  'ok': true,
  'expiresAt': '2026-11-17T15:00:00Z',
  'clubSlug': _demoSlug,
};

const _pilotApproved = {
  'pilot': {
    'id': 'p1',
    'name': 'Demo Pilot',
    'email': 'pilot@demo.test',
    'status': 'approved',
    'role': 'pilot',
    'licenseNo': 'L-1',
  },
};

const _guestSession = {
  'pilot': {
    'id': 'g1',
    'name': 'Guest',
    'email': 'guest@test',
    'status': 'approved',
    'role': 'pilot',
  },
};

class _MemorySecureStore extends SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> readDeviceToken() async => _values['device'];

  @override
  Future<String?> readSessionId() async => _values['session'];

  @override
  Future<void> writeDeviceToken(String token) async => _values['device'] = token;

  @override
  Future<void> writeSessionId(String sessionId) async => _values['session'] = sessionId;

  @override
  Future<void> clearDeviceToken() async => _values.remove('device');

  @override
  Future<void> clearSessionId() async => _values.remove('session');

  @override
  Future<void> clearAll() async => _values.clear();
}

http_testing.MockClient _mockHttp({
  required int Function() checkinPostCount,
  Future<void>? delayBeforeClubMe,
  Future<void>? delayBeforeGuest,
}) {
  return http_testing.MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith(FlightVisApiPaths.checkin)) {
      checkinPostCount();
      return http.Response(jsonEncode(_checkinSuccess), 200);
    }
    if (request.method == 'GET' && path.endsWith(FlightVisApiPaths.clubMe)) {
      if (delayBeforeClubMe != null) await delayBeforeClubMe;
      return http.Response(jsonEncode(_pilotApproved), 200);
    }
    if (request.method == 'POST' && path.endsWith(FlightVisApiPaths.devicesAnonymous)) {
      if (delayBeforeGuest != null) await delayBeforeGuest;
      return http.Response(
        jsonEncode(_guestSession),
        200,
        headers: {'set-cookie': 'fv_club_session=guest-sess; Path=/'},
      );
    }
    if (request.method == 'POST' && path.endsWith(FlightVisApiPaths.meDevices)) {
      return http.Response(jsonEncode({'token': _deviceToken}), 200);
    }
  if (path.contains('/clubs/')) {
      return http.Response(jsonEncode({'slug': _demoSlug, 'name': 'Demo Club'}), 200);
    }
    return http.Response('{}', 200);
  });
}

Future<AppRepository> _buildLoggedInRepo({
  required int Function() checkinPostCount,
  Map<String, Object> prefs = const {},
  Future<void>? delayBeforeClubMe,
}) async {
  SharedPreferences.setMockInitialValues({
    PreferencesStore.permissionsOnboardingKey: true,
    PreferencesStore.pendingCheckinSlugKey: _demoSlug,
    PreferencesStore.pendingCheckinTokenKey: _kioskToken,
    ...prefs,
  });
  final store = await PreferencesStore.open();
  final secure = _MemorySecureStore();
  await secure.writeSessionId(_sessionId);
  await secure.writeDeviceToken(_deviceToken);

  final client = FlightVisClient(
    baseUrl: store.baseUrl(),
    httpClient: _mockHttp(
      checkinPostCount: checkinPostCount,
      delayBeforeClubMe: delayBeforeClubMe,
    ),
    sessionId: _sessionId,
    deviceToken: _deviceToken,
    clubSlug: _demoSlug,
  );

  return AppRepository(secure: secure, prefs: store, client: client);
}

Future<void> _pumpApp(WidgetTester tester, AppRepository repo) async {
  await tester.pumpWidget(FlightVisApp(repo: repo, bindPlatformDeepLinks: false));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _settleFrames(WidgetTester tester, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  testWidgets('login with pending token opens one CheckinScreen and one check-in POST', (tester) async {
    var checkins = 0;
    final repo = await _buildLoggedInRepo(checkinPostCount: () => checkins++);
    await _pumpApp(tester, repo);
    await _settleFrames(tester, rounds: 80);

    expect(checkins, 1);
    expect(find.byType(CheckinScreen), findsOneWidget);

    final onLoggedIn = flightVisAppOnLoggedInTestHook;
    expect(onLoggedIn, isNotNull);
    await onLoggedIn!();
    await _settleFrames(tester);

    expect(checkins, 1, reason: '_onLoggedIn must not present pending check-in twice');
    expect(find.byType(CheckinScreen), findsOneWidget);
  });

  testWidgets('queued deep link during restore opens one check-in', (tester) async {
    var checkins = 0;
    final unblockMe = Completer<void>();
    SharedPreferences.setMockInitialValues({
      PreferencesStore.permissionsOnboardingKey: true,
    });
    final prefs = await PreferencesStore.open();
    final secure = _MemorySecureStore();
    await secure.writeSessionId(_sessionId);
    await secure.writeDeviceToken(_deviceToken);
    final client = FlightVisClient(
      baseUrl: prefs.baseUrl(),
      httpClient: _mockHttp(
        checkinPostCount: () => checkins++,
        delayBeforeClubMe: unblockMe.future,
      ),
      sessionId: _sessionId,
      deviceToken: _deviceToken,
    );
    final repo = AppRepository(secure: secure, prefs: prefs, client: client);

    await tester.pumpWidget(FlightVisApp(repo: repo, bindPlatformDeepLinks: false));
    await tester.pump();
    await DeepLinkTestHooks.dispatch(
      const CheckinDeepLink(clubSlug: _demoSlug, token: _kioskToken),
    );
    unblockMe.complete();
    await _settleFrames(tester, rounds: 80);

    expect(find.byType(CheckinScreen), findsOneWidget);
    expect(checkins, 1);
  });

  testWidgets('duplicate deep-link dispatch is single-flight', (tester) async {
    var checkins = 0;
    SharedPreferences.setMockInitialValues({
      PreferencesStore.permissionsOnboardingKey: true,
    });
    final prefs = await PreferencesStore.open();
    final secure = _MemorySecureStore();
    await secure.writeSessionId(_sessionId);
    await secure.writeDeviceToken(_deviceToken);
    final repo = AppRepository(
      secure: secure,
      prefs: prefs,
      client: FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: _mockHttp(checkinPostCount: () => checkins++),
        sessionId: _sessionId,
        deviceToken: _deviceToken,
      ),
    );

    await _pumpApp(tester, repo);
    await _settleFrames(tester, rounds: 30);
    expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);

    const link = CheckinDeepLink(clubSlug: _demoSlug, token: _kioskToken);
    await DeepLinkTestHooks.dispatch(link);
    await DeepLinkTestHooks.dispatch(link);
    await _settleFrames(tester);

    expect(checkins, 1);
    expect(find.byType(CheckinScreen), findsOneWidget);
  });
}