import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/l10n/api_errors.dart';
import 'package:flight_vis/l10n/app_localizations_en.dart';
import 'package:flight_vis/l10n/app_localizations_es.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/screens/checkin_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/services/launch_intent_bridge.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import '../tool/spanish_voseo.dart';

const _claimToken = 'h1.club1.0123456789abcdef0123456789abcdef';
const _demoSlug = 'demo-club';
const _rawDeviceId = 'dev-raw-id-not-a-token';
const _issuedDeviceToken = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6';

class _MemorySecureStore extends SecureStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> readDeviceToken() async => _values['device'];

  @override
  Future<String?> readSessionId() async => _values['session'];

  @override
  Future<void> writeDeviceToken(String token) async => _values['device'] = token.trim();

  @override
  Future<void> writeSessionId(String sessionId) async => _values['session'] = sessionId.trim();

  @override
  Future<void> clearDeviceToken() async => _values.remove('device');

  @override
  Future<void> clearSessionId() async => _values.remove('session');

  @override
  Future<void> clearAll() async => _values.clear();
}

class _RecordingTracker extends Fake implements TraccarClientSdk {
  Config? lastInitConfig;
  Config? lastSetConfig;
  bool started = false;

  @override
  Future<void> init(Config config) async {
    lastInitConfig = config;
  }

  @override
  Future<void> setConfig(Config config) async {
    lastSetConfig = config;
  }

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<bool> isTracking() async => started;

  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

class _FakeAppLinks extends Fake implements AppLinks {
  _FakeAppLinks({this.initialLink});

  final Uri? initialLink;
  final _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriLinkStream => _controller.stream;

  Future<void> close() => _controller.close();
}

class _FakeLaunchBridge extends LaunchIntentBridge {
  _FakeLaunchBridge(this.link);

  final ParsedDeepLink? link;

  @override
  Future<ParsedDeepLink?> readInitialDeepLink() async => link;
}

Future<void> _settle(WidgetTester tester, {int rounds = 50}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (!tester.binding.hasScheduledFrame) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  group('(1) Skip session-gated calls when there is no session', () {
    test('FlightVisClient skips /api/me/devices, /api/club/me, /api/me/flights, /api/club/logout without session', () async {
      final calls = <String>[];
      final client = FlightVisClient(
        baseUrl: 'https://example.test',
        httpClient: http_testing.MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }),
      );

      expect(client.hasSession, isFalse);
      expect(await client.registerDevice(installId: 'install-1'), isNull);
      expect(await client.meProfile(), isNull);
      expect(await client.myFlights(), isEmpty);
      await client.logout();

      expect(calls, isEmpty, reason: 'No session-only endpoints may be called without a session');
    });

    test('registerDevice treats PR #36 ignored:true and 401 as null without throwing', () async {
      final ignoredClient = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'stale-sess',
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, FlightVisApiPaths.meDevices);
          return http.Response(jsonEncode({'ok': true, 'ignored': true}), 200);
        }),
      );
      expect(await ignoredClient.registerDevice(installId: 'install-1'), isNull);

      final unauthClient = FlightVisClient(
        baseUrl: 'https://example.test',
        sessionId: 'stale-sess',
        httpClient: http_testing.MockClient((request) async {
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }),
      );
      expect(await unauthClient.registerDevice(installId: 'install-1'), isNull);
    });

    test('AppRepository.ensureDeviceRegistered skips /api/me/devices when no session exists', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      final calls = <String>[];
      final client = FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: http_testing.MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-test-install-01',
      );

      await repo.ensureDeviceRegistered();
      expect(calls, isEmpty);
      expect(await secure.readDeviceToken(), isNull);
    });

    testWidgets('cold start without session makes zero session-gated requests and reaches hub', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      final calls = <String>[];
      final client = FlightVisClient(
        baseUrl: prefs.baseUrl(),
        httpClient: http_testing.MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-test-install-01',
      );

      await tester.pumpWidget(FlightVisApp(
        repo: repo,
        bindPlatformDeepLinks: false,
        stopStickyTrackerOnRestore: false,
      ));
      await _settle(tester);

      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
      expect(calls, isEmpty);
    });
  });

  group('(2) Claim/handoff token flow, guest device issuance, and OsmAnd device token', () {
    testWidgets('guest first scan carries h1 claim token to POST /api/checkin, skips /api/me/devices, and stores device token for /api/osmand', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      final calls = <String>[];
      String? checkinBodyToken;
      String? checkinCookie;
      String? checkinAuth;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.method == 'POST' && request.url.path == FlightVisApiPaths.devicesAnonymous) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'pilot': {
                  'id': 'guest-1',
                  'name': 'Guest',
                  'email': 'guest-1@guest.invalid',
                  'status': 'guest',
                  'role': 'pilot',
                },
              }),
              200,
              headers: {'set-cookie': 'fv_club_session=guest-sess-1; Path=/; HttpOnly'},
            );
          }
          if (request.method == 'POST' && request.url.path == FlightVisApiPaths.checkin) {
            final decoded = jsonDecode(request.body) as Map<String, dynamic>;
            checkinBodyToken = decoded['token'] as String?;
            checkinCookie = request.headers['Cookie'];
            checkinAuth = request.headers['Authorization'];
            return http.Response(
              jsonEncode({
                'ok': true,
                'id': 'chk-1',
                'expiresAt': '2099-01-01T15:00:00Z',
                'status': 'guest',
                'needsSignup': true,
                'deviceId': _rawDeviceId,
                'token': _issuedDeviceToken,
              }),
              200,
            );
          }
          if (request.method == 'GET' && request.url.path == '/api/clubs/$_demoSlug') {
            return http.Response(
              jsonEncode({
                'club': {
                  'id': 'club1',
                  'slug': _demoSlug,
                  'name': 'Club Demo',
                  'defaultLocale': 'es',
                },
              }),
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );

      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-test-install-01',
      );

      await tester.pumpWidget(FlightVisApp(
        repo: repo,
        bindPlatformDeepLinks: false,
        stopStickyTrackerOnRestore: false,
      ));
      await _settle(tester);

      // Simulate App Link from browser landing page carrying the h1 claim token.
      final parsed = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/c/$_demoSlug/q/$_claimToken'),
      );
      expect(parsed, isA<CheckinDeepLink>());
      expect((parsed! as CheckinDeepLink).isClaimToken, isTrue);

      await DeepLinkTestHooks.dispatch(parsed);
      await _settle(tester);

      expect(find.byType(CheckinScreen), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.checkinContinue), findsOneWidget);

      // Verify exact PR #36 request sequence: anonymous guest session -> checkin -> club info; no /api/me/devices.
      expect(calls, isNot(contains('POST ${FlightVisApiPaths.meDevices}')));
      expect(calls.take(2).toList(), [
        'POST ${FlightVisApiPaths.devicesAnonymous}',
        'POST ${FlightVisApiPaths.checkin}',
      ]);
      expect(checkinBodyToken, _claimToken);
      expect(checkinCookie, 'fv_club_session=guest-sess-1');
      expect(checkinAuth, isNull);

      // Device token (NOT raw device id) persisted and used for /api/osmand.
      final storedToken = await secure.readDeviceToken();
      expect(storedToken, _issuedDeviceToken);
      expect(storedToken, isNot(_rawDeviceId));
      expect(client.deviceToken, _issuedDeviceToken);
      expect(prefs.activeClubSlug(), _demoSlug);
      expect(prefs.activeClubName(), 'Club Demo');

      // TrackingService configures Traccar SDK with the device token for /api/osmand.
      final tracker = _RecordingTracker();
      final tracking = TrackingService(tracker: tracker);
      await tracking.initForFlight(
        baseUrl: prefs.baseUrl(),
        deviceToken: storedToken!,
        checkinExpiresAtMs: prefs.checkinExpiresAtMs(),
      );
      expect(tracker.lastInitConfig?.serverUrl, 'https://flight.heavenly.cl/api/osmand');
      expect(tracker.lastInitConfig?.deviceId, _issuedDeviceToken);
      expect(tracker.lastSetConfig?.deviceId, _issuedDeviceToken);
      expect(tracker.lastSetConfig?.deviceId, isNot(_rawDeviceId));
    });

    test('guest check-in falls back to POST /api/me/devices with guest session when /api/checkin omits token', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      final calls = <String>[];
      String? devicesCookie;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == FlightVisApiPaths.devicesAnonymous) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'pilot': {
                  'id': 'guest-2',
                  'name': 'Guest',
                  'email': 'guest-2@guest.invalid',
                  'status': 'guest',
                  'role': 'pilot',
                },
              }),
              200,
              headers: {'set-cookie': 'fv_club_session=guest-sess-2; Path=/'},
            );
          }
          if (request.url.path == FlightVisApiPaths.checkin) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'id': 'chk-2',
                'expiresAt': '2099-01-01T15:00:00Z',
                'status': 'guest',
                'needsSignup': true,
                'club': {'slug': _demoSlug, 'name': 'Club Demo'},
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.meDevices) {
            devicesCookie = request.headers['Cookie'];
            return http.Response(
              jsonEncode({
                'id': _rawDeviceId,
                'token': _issuedDeviceToken,
                'label': 'Android',
                'created': true,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-test-install-02',
      );

      final result = await repo.submitCheckin(_claimToken, clubSlug: _demoSlug);
      expect(result.ok, isTrue);
      expect(result.isGuest, isTrue);
      expect(calls, [
        'POST ${FlightVisApiPaths.devicesAnonymous}',
        'POST ${FlightVisApiPaths.checkin}',
        'POST ${FlightVisApiPaths.meDevices}',
      ]);
      expect(devicesCookie, 'fv_club_session=guest-sess-2');
      expect(await secure.readDeviceToken(), _issuedDeviceToken);
      expect(await secure.readDeviceToken(), isNot(_rawDeviceId));
    });

    testWidgets('persisted pending h1 claim token resumes for guest on launch', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.pendingCheckinSlugKey: _demoSlug,
        PreferencesStore.pendingCheckinTokenKey: _claimToken,
      });
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      String? submittedToken;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.devicesAnonymous) {
            return http.Response(
              jsonEncode({
                'ok': true,
                'pilot': {
                  'id': 'guest-3',
                  'name': 'Guest',
                  'email': 'guest-3@guest.invalid',
                  'status': 'guest',
                  'role': 'pilot',
                },
              }),
              200,
              headers: {'set-cookie': 'fv_club_session=guest-sess-3; Path=/'},
            );
          }
          if (request.url.path == FlightVisApiPaths.checkin) {
            submittedToken = (jsonDecode(request.body) as Map)['token'] as String?;
            return http.Response(
              jsonEncode({
                'ok': true,
                'expiresAt': '2099-01-01T15:00:00Z',
                'status': 'guest',
                'needsSignup': true,
                'deviceId': _rawDeviceId,
                'token': _issuedDeviceToken,
                'club': {'slug': _demoSlug, 'name': 'Club Demo'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);

      await tester.pumpWidget(FlightVisApp(
        repo: repo,
        bindPlatformDeepLinks: false,
        stopStickyTrackerOnRestore: false,
      ));
      await _settle(tester);

      expect(find.byType(CheckinScreen), findsOneWidget);
      expect(submittedToken, _claimToken);
      expect(await secure.readDeviceToken(), _issuedDeviceToken);
    });

    test('DeepLinkDispatcher deduplicates identical initial claim link from platform bridge and AppLinks', () async {
      final uri = Uri.parse('https://flight.heavenly.cl/c/$_demoSlug/q/$_claimToken');
      const expected = CheckinDeepLink(clubSlug: _demoSlug, token: _claimToken);
      final fakeAppLinks = _FakeAppLinks(initialLink: uri);
      final dispatcher = DeepLinkDispatcher(
        appLinks: fakeAppLinks,
        launchBridge: _FakeLaunchBridge(expected),
      );

      final received = <ParsedDeepLink>[];
      await dispatcher.bind((link) async => received.add(link));
      await dispatcher.dispose();
      await fakeAppLinks.close();

      expect(received, [expected]);
    });
  });

  group('(3) Localized check-in rejection messages (es-CL tú & en)', () {
    final es = AppLocalizationsEs();
    final en = AppLocalizationsEn();

    const reasonCodes = [
      'expired_qr',
      'old_step',
      'used_qr',
      'replay',
      'expired_claim',
      'used_claim',
      'no_device',
      'invalid_device',
      'not_cleared',
      'club_mismatch',
      'wrong_club',
      'club_unavailable',
      'format',
      'forged_hmac',
      'rate_limited',
      'guest_failed',
      'device_cap',
      'invalid_install_id',
      'not_approved',
      'no_session',
      'db_error',
    ];

    test('every server reason code maps to a friendly es-CL (voseo-free) and en message', () {
      for (final code in reasonCodes) {
        final esMsg = localizeApiException(
          es,
          FlightVisException(code, statusCode: 403, reason: code, body: {'error': code, 'reason': code}),
        );
        final enMsg = localizeApiException(
          en,
          FlightVisException(code, statusCode: 403, reason: code, body: {'error': code, 'reason': code}),
        );
        expect(esMsg, isNotEmpty, reason: 'es missing for $code');
        expect(enMsg, isNotEmpty, reason: 'en missing for $code');
        expect(esMsg, isNot(equals(code)), reason: 'es must not show raw code $code');
        expect(enMsg, isNot(equals(code)), reason: 'en must not show raw code $code');
        expect(
          findSpanishVoseoViolations(esMsg),
          isEmpty,
          reason: 'es message for $code must not contain voseo: "$esMsg"',
        );
      }

      // Legacy "not cleared for <tail>" still localizes cleanly.
      expect(
        localizeApiException(
          es,
          FlightVisException('not cleared for CC-ABC / C172', statusCode: 403),
        ),
        es.errorCheckInNotCleared,
      );
      expect(
        localizeApiException(
          en,
          FlightVisException('not cleared for CC-ABC / C172', statusCode: 403),
        ),
        en.errorCheckInNotCleared,
      );

      // Unknown raw snake_case reason falls back to generic message, never leaks raw code.
      expect(
        localizeApiException(
          en,
          FlightVisException('mystery_server_code', statusCode: 400, reason: 'mystery_server_code'),
        ),
        en.errorGeneric,
      );
    });

    Future<void> expectCheckinRejectionUi(
      WidgetTester tester, {
      required Locale locale,
      required int statusCode,
      required String reason,
      required String expectedMessage,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _MemorySecureStore();
      await secure.writeDeviceToken(_issuedDeviceToken);

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        deviceToken: _issuedDeviceToken,
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, FlightVisApiPaths.checkin);
          return http.Response(
            jsonEncode({
              'error': reason,
              'reason': reason,
              'message': 'server fallback',
            }),
            statusCode,
          );
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);

      await tester.pumpWidget(
        PilotAppShell(
          locale: locale,
          home: CheckinScreen(
            key: ValueKey('${locale.languageCode}-$reason'),
            repo: repo,
            initialScan: _claimToken,
            initialClubSlug: _demoSlug,
            onCheckedIn: () {},
          ),
        ),
      );
      await _settle(tester);

      expect(find.text(expectedMessage), findsOneWidget);
      expect(find.text(reason), findsNothing);
    }

    testWidgets('CheckinScreen shows friendly es-CL messages for PR #36 rejection reasons', (tester) async {
      final cases = <(int, String, String)>[
        (409, 'used_claim', es.errorCheckInUsedClaim),
        (403, 'expired_claim', es.errorCheckInExpiredClaim),
        (409, 'used_qr', es.errorCheckInUsedQr),
        (403, 'expired_qr', es.errorCheckInExpiredQr),
        (403, 'club_mismatch', es.errorCheckInClubMismatch),
        (403, 'wrong_club', es.errorCheckInClubMismatch),
        (403, 'forged_hmac', es.errorCheckInInvalidToken),
        (401, 'no_device', es.errorCheckInNoDevice),
        (403, 'invalid_device', es.errorCheckInInvalidDevice),
        (403, 'not_cleared', es.errorCheckInNotCleared),
      ];
      for (final (status, reason, expected) in cases) {
        await expectCheckinRejectionUi(
          tester,
          locale: const Locale('es', 'CL'),
          statusCode: status,
          reason: reason,
          expectedMessage: expected,
        );
      }
    });

    testWidgets('CheckinScreen shows friendly English messages for PR #36 rejection reasons', (tester) async {
      await expectCheckinRejectionUi(
        tester,
        locale: const Locale('en'),
        statusCode: 409,
        reason: 'used_claim',
        expectedMessage: en.errorCheckInUsedClaim,
      );
      await expectCheckinRejectionUi(
        tester,
        locale: const Locale('en'),
        statusCode: 403,
        reason: 'expired_claim',
        expectedMessage: en.errorCheckInExpiredClaim,
      );
      await expectCheckinRejectionUi(
        tester,
        locale: const Locale('en'),
        statusCode: 403,
        reason: 'forged_hmac',
        expectedMessage: en.errorCheckInInvalidToken,
      );
      await expectCheckinRejectionUi(
        tester,
        locale: const Locale('en'),
        statusCode: 403,
        reason: 'club_mismatch',
        expectedMessage: en.errorCheckInClubMismatch,
      );
    });
  });
}
