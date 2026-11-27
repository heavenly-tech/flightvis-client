import 'dart:convert';

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
import 'package:flight_vis/l10n/api_errors.dart';
import 'package:flight_vis/l10n/app_localizations_en.dart';
import 'package:flight_vis/l10n/app_localizations_es.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/map/map_tile_config.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/login_screen.dart';
import 'package:flight_vis/screens/personal_flight_start_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/flight_start_mode.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/tracking_lifecycle.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/state/checkin_gate.dart';
import 'package:flight_vis/storage/fix_upload_queue.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import 'helpers/fake_tile_provider.dart';

class _InMemorySecure extends SecureStore {
  _InMemorySecure({
    this.sessionId,
    this.accountSessionId,
    this.deviceToken,
    this.personalDeviceToken,
  });

  String? sessionId;
  String? accountSessionId;
  String? deviceToken;
  String? personalDeviceToken;

  @override
  Future<String?> readDeviceToken() async => deviceToken;
  @override
  Future<void> writeDeviceToken(String token) async =>
      deviceToken = token.trim();
  @override
  Future<void> clearDeviceToken() async => deviceToken = null;

  @override
  Future<String?> readPersonalDeviceToken() async => personalDeviceToken;
  @override
  Future<void> writePersonalDeviceToken(String token) async =>
      personalDeviceToken = token.trim();
  @override
  Future<void> clearPersonalDeviceToken() async => personalDeviceToken = null;

  @override
  Future<String?> readSessionId() async => sessionId;
  @override
  Future<void> writeSessionId(String id) async => sessionId = id.trim();
  @override
  Future<void> clearSessionId() async => sessionId = null;

  @override
  Future<String?> readAccountSessionId() async => accountSessionId;
  @override
  Future<void> writeAccountSessionId(String id) async =>
      accountSessionId = id.trim();
  @override
  Future<void> clearAccountSessionId() async => accountSessionId = null;

  @override
  Future<void> clearAll() async {
    deviceToken = null;
    personalDeviceToken = null;
    sessionId = null;
    accountSessionId = null;
  }
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

class _FakeTracker extends Fake implements TraccarClientSdk {
  bool started = false;
  int stopCalls = 0;
  Config? lastConfig;
  List<LogEntry> logs = const [];

  @override
  Future<void> init(Config config) async {
    lastConfig = config;
  }

  @override
  Future<void> setConfig(Config config) async {
    lastConfig = config;
  }

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
    stopCalls++;
  }

  @override
  Future<bool> isTracking() async => started;

  @override
  Future<List<LogEntry>> getLogs() async => logs;
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

  group('normalizePersonalTail & FlightStartMode.personalBroadcast', () {
    test('normalizes valid tails and rejects invalid shapes', () {
      expect(normalizePersonalTail('  cc-abc  '), 'CC-ABC');
      expect(normalizePersonalTail('n12345'), 'N12345');
      expect(normalizePersonalTail('A'), 'A');
      expect(normalizePersonalTail('1234567890123456'), '1234567890123456');
      expect(normalizePersonalTail(''), isNull);
      expect(normalizePersonalTail('   '), isNull);
      expect(normalizePersonalTail('---'), isNull);
      expect(normalizePersonalTail('12345678901234567'), isNull);
      expect(normalizePersonalTail('CC ABC'), isNull);
      expect(normalizePersonalTail('CC_ABC'), isNull);
    });

    test('resolves personalBroadcast for club-less accounts and club members choosing personal mode', () {
      final clubless = PilotProfile(
        id: 'acct-1',
        name: 'pubpilot',
        email: 'pub@example.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: true,
        isClublessAccount: true,
      );
      final clubMember = PilotProfile(
        id: 'pilot-1',
        name: 'Club Pilot',
        email: 'member@club.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: true,
      );

      // Club-less account -> personalBroadcast with NO check-in.
      final resClubless = resolveFlightStartMode(
        pilot: clubless,
        checkinGate: CheckinGate(expiresAtMs: null, nowMs: 1000),
      );
      expect(resClubless.mode, FlightStartMode.personalBroadcast);

      // Club member explicitly choosing Piloto público -> personalBroadcast with NO check-in.
      final resChosenPersonal = resolveFlightStartMode(
        pilot: clubMember,
        checkinGate: CheckinGate(expiresAtMs: null, nowMs: 1000),
        preferPersonalBroadcast: true,
        hasAccountSession: true,
      );
      expect(resChosenPersonal.mode, FlightStartMode.personalBroadcast);

      // Club member in club mode with valid check-in -> clubBroadcast unchanged.
      final resClub = resolveFlightStartMode(
        pilot: clubMember,
        checkinGate: CheckinGate(expiresAtMs: 9000, nowMs: 1000),
        preferPersonalBroadcast: false,
        hasAccountSession: true,
      );
      expect(resClub.mode, FlightStartMode.clubBroadcast);
    });
  });

  group('Account magic-link App Link -> complete -> signed-in state', () {
    testWidgets('dispatches AccountMagicLinkDeepLink, sends exact complete body, stores account session + personal device token, and refreshes /api/account/me', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure();

      Map<String, dynamic>? completeBody;
      String? meCookieHeader;
      var meCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.accountAuthMagicComplete) {
            completeBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-magic-1',
                  'email': 'libre@example.cl',
                  'emailVerified': true,
                  'emailVerifiedAt': 1700000000000,
                },
                'activeMembershipId': null,
                'memberships': [],
                'device': {
                  'id': 'dev-pers-1',
                  'token': 'personal_tok_0123456789abcdef0123456789',
                  'label': 'Android',
                },
              }),
              200,
              headers: {
                'set-cookie':
                    'fv_account_session=acct-sess-xyz; Path=/; HttpOnly; SameSite=Lax, '
                        '__Host-fv_account_signup_nonce=; Path=/; Max-Age=0',
              },
            );
          }
          if (request.method == 'GET' &&
              request.url.path == FlightVisApiPaths.accountMe) {
            meCalls++;
            meCookieHeader = request.headers['Cookie'];
            return http.Response(
              jsonEncode({
                'account': {
                  'id': 'acct-magic-1',
                  'email': 'libre@example.cl',
                  'emailVerifiedAt': 1700000000000,
                },
                'email_verified': true,
                'skipCurrentPassword': true,
                'activeMembershipId': null,
                'memberships': [],
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
        installIdProvider: () async => 'fv-install-test-99',
        deviceModelProvider: () async => 'Pixel 8',
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
          permissions: _GrantedPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // Initially signed out on Hub.
      expect(find.byKey(FlightVisTestKeys.hubSignIn), findsOneWidget);

      // M-30: record a fresh local magic-link request marker so this install
      // auto-completes the link it just requested without prompting.
      await prefs.recordMagicLinkRequest(
        email: 'libre@example.cl',
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      // Dispatch the App Link parsed from https://flight.heavenly.cl/api/account/auth/magic
      final parsed = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=tok_magic_e1&purpose=account_signup',
        ),
      );
      expect(parsed, isA<AccountMagicLinkDeepLink>());
      await DeepLinkTestHooks.dispatch(parsed!);
      await tester.pumpAndSettle();

      // Exact body verified against server `AccountMagicCompleteBody` (`account_routes.rs:1090-1100`).
      expect(completeBody, {
        'token': 'tok_magic_e1',
        'purpose': 'account_signup',
        'installId': 'fv-install-test-99',
        'label': 'Android',
        'model': 'Pixel 8',
      });

      // Session cookie + personal device token persisted; /api/account/me refreshed.
      expect(await secure.readAccountSessionId(), 'acct-sess-xyz');
      expect(
        await secure.readPersonalDeviceToken(),
        'personal_tok_0123456789abcdef0123456789',
      );
      expect(client.accountSessionId, 'acct-sess-xyz');
      expect(meCalls, 1);
      expect(meCookieHeader, contains('fv_account_session=acct-sess-xyz'));

      // App is now signed in on Hub in "Piloto público (sin club)" mode.
      expect(find.byKey(FlightVisTestKeys.hubSignIn), findsNothing);
      expect(find.text('Piloto público (sin club)'), findsOneWidget);
      expect(find.text('Transmitir como piloto público'), findsOneWidget);
    });
  });

  group('Account login & club-less signup on LoginScreen', () {
    testWidgets('LoginScreen password login uses POST /api/account/login with installId and signup posts POST /api/account/signup without clubSlug', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure();

      Map<String, dynamic>? signupBody;
      Map<String, dynamic>? loginBody;
      var loggedInCalled = false;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.accountSignup) {
            signupBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(jsonEncode({'ok': true}), 201);
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.accountLogin) {
            loginBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-pw-1',
                  'email': 'libre@example.cl',
                  'emailVerified': true,
                  'emailVerifiedAt': 1700000000000,
                },
                'activeMembershipId': null,
                'memberships': [],
                'device': {
                  'id': 'dev-pw-1',
                  'token': 'personal_pw_tok_0123456789abcdef0123456',
                  'label': 'Android',
                },
              }),
              200,
              headers: {
                'set-cookie': 'fv_account_session=acct-pw-sess; Path=/',
              },
            );
          }
          if (request.method == 'GET' &&
              request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {
                  'id': 'acct-pw-1',
                  'email': 'libre@example.cl',
                  'emailVerifiedAt': 1700000000000,
                },
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );

      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-install-login',
        deviceModelProvider: () async => 'Pixel 8a',
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LoginScreen(
            repo: repo,
            onLoggedIn: () => loggedInCalled = true,
            signupAvailabilityProbe: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. In-app club-less signup (no clubSlug).
      await tester.tap(find.byKey(FlightVisTestKeys.loginRegister));
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.loginSignupDialog), findsOneWidget);
      await tester.enterText(
        find.byKey(FlightVisTestKeys.loginSignupEmail),
        'nuevo@example.cl',
      );
      await tester.tap(find.byKey(FlightVisTestKeys.loginSignupSubmit));
      await tester.pumpAndSettle();

      expect(signupBody, {'email': 'nuevo@example.cl'});
      expect(signupBody!.containsKey('clubSlug'), isFalse);
      expect(
        find.text(
          'Te enviamos un enlace mágico a tu correo. Ábrelo en este teléfono para entrar.',
        ),
        findsOneWidget,
      );

      // 2. Account email+password login sends installId/label/model to /api/account/login.
      await tester.enterText(
        find.widgetWithText(TextField, 'Correo'),
        'libre@example.cl',
      );
      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Contraseña'),
        'secret1234',
      );
      await tester.tap(find.text('Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(loginBody, {
        'email': 'libre@example.cl',
        'password': 'secret1234',
        'installId': 'fv-install-login',
        'label': 'Android',
        'model': 'Pixel 8a',
      });
      expect(loggedInCalled, isTrue);
      expect(await secure.readAccountSessionId(), 'acct-pw-sess');
      expect(
        await secure.readPersonalDeviceToken(),
        'personal_pw_tok_0123456789abcdef0123456',
      );
    });
  });

  group('Personal broadcast flight start & error mappings', () {
    testWidgets('personal start registers personal device if missing, sends mode=personal + normalized tail with NO check-in', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure(
        accountSessionId: 'acct-sess-1',
        // Club device token exists; personal token is absent and must be minted separately.
        deviceToken: 'club_tok_should_not_be_used_0123456789',
      );

      Map<String, dynamic>? deviceBody;
      Map<String, dynamic>? startBody;
      String? startAuthHeader;
      var checkinCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess-1',
        deviceToken: 'club_tok_should_not_be_used_0123456789',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.checkin) {
            checkinCalls++;
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.accountDevices) {
            deviceBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'dev-personal-9',
                'token': 'personal_minted_tok_0123456789abcdef01',
                'label': 'Android',
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.flights) {
            startBody = jsonDecode(request.body) as Map<String, dynamic>;
            startAuthHeader = request.headers['Authorization'];
            return http.Response(
              jsonEncode({
                'id': 'flt-personal-1',
                'visibility': startBody!['visibility'],
                'showPilotNamePublic': startBody!['show_pilot_name_public'],
                'trailMinutes': null,
                'effectiveTrailMinutes': 5,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );

      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'fv-install-pers',
        deviceModelProvider: () async => 'Pixel 9',
      );

      final verifiedPilot = PilotProfile(
        id: 'acct-1',
        name: 'libre',
        email: 'libre@example.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: true,
        isClublessAccount: true,
      );

      String? startedId;
      String? startedTail;

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: PersonalFlightStartScreen(
            repo: repo,
            pilot: verifiedPilot,
            permissions: _GrantedPermissions(),
            onFlightStarted: (flight, tail) {
              startedId = flight.id;
              startedTail = tail;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Club visibility option must NEVER appear in personal mode.
      await tester.tap(find.text('Público'));
      await tester.pumpAndSettle();
      expect(find.text('Club'), findsNothing);
      expect(find.text('Privado'), findsOneWidget);
      await tester.tap(find.text('Público').last);
      await tester.pumpAndSettle();

      // Enter mixed-case tail with spaces/invalid punctuation -> formatter & normalizer produce CC-PUB1.
      await tester.enterText(
        find.byKey(FlightVisTestKeys.personalFlightTailField),
        '  cc-pub1! ',
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(FlightVisTestKeys.personalFlightStart));
      await tester.tap(find.byKey(FlightVisTestKeys.personalFlightStart));
      await tester.pumpAndSettle();

      expect(checkinCalls, 0);
      expect(deviceBody, {
        'mode': 'personal',
        'label': 'Android',
        'installId': 'fv-install-pers',
        'model': 'Pixel 9',
      });
      expect(startBody, {
        'mode': 'personal',
        'tail': 'CC-PUB1',
        'visibility': 'public',
        'show_pilot_name_public': false,
      });
      expect(
        startAuthHeader,
        'Bearer personal_minted_tok_0123456789abcdef01',
      );
      // Club token untouched; personal token stored separately.
      expect(
        await secure.readDeviceToken(),
        'club_tok_should_not_be_used_0123456789',
      );
      expect(
        await secure.readPersonalDeviceToken(),
        'personal_minted_tok_0123456789abcdef01',
      );
      expect(startedId, 'flt-personal-1');
      expect(startedTail, 'CC-PUB1');
    });

    testWidgets('hides public visibility when emailVerified is false and defaults to private', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure(
        accountSessionId: 'acct-sess-unv',
        personalDeviceToken: 'personal_unv_tok_0123456789abcdef01234',
      );
      Map<String, dynamic>? startBody;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess-unv',
        personalDeviceToken: 'personal_unv_tok_0123456789abcdef01234',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.flights) {
            startBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'flt-priv-1',
                'visibility': 'private',
                'showPilotNamePublic': false,
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final unverified = PilotProfile(
        id: 'acct-unv',
        name: 'unverified',
        email: 'unv@example.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: false,
        isClublessAccount: true,
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: PersonalFlightStartScreen(
            repo: repo,
            pilot: unverified,
            permissions: _GrantedPermissions(),
            onFlightStarted: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Verifica tu correo para transmitir de forma pública.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Privado'));
      await tester.pumpAndSettle();
      expect(find.text('Público'), findsNothing);
      await tester.tap(find.text('Privado').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(FlightVisTestKeys.personalFlightTailField),
        'CC-PRV',
      );
      await tester.tap(find.byKey(FlightVisTestKeys.personalFlightStart));
      await tester.pumpAndSettle();

      expect(startBody?['mode'], 'personal');
      expect(startBody?['visibility'], 'private');
      expect(startBody?['tail'], 'CC-PRV');
    });

    test('maps 400 club_visibility_requires_club, 403 email_not_verified/email_unverified, and 429 rate limited in es-CL & en', () {
      final es = AppLocalizationsEs();
      final en = AppLocalizationsEn();

      final errClubVis = FlightVisException(
        'club_visibility_requires_club',
        statusCode: 400,
        body: {'error': 'club_visibility_requires_club'},
      );
      expect(
        localizeApiException(es, errClubVis),
        'La visibilidad de club requiere pertenecer a un club.',
      );
      expect(
        localizeApiException(en, errClubVis),
        'Club visibility requires a club membership.',
      );

      for (final code in ['email_not_verified', 'email_unverified']) {
        final errUnv = FlightVisException(
          code,
          statusCode: 403,
          body: {'error': code},
        );
        expect(
          localizeApiException(es, errUnv),
          'Verifica tu correo para compartir vuelos en público.',
        );
        expect(
          localizeApiException(en, errUnv),
          'Verify your email to share flights publicly.',
        );
      }

      final errRate = FlightVisException(
        'rate limited',
        statusCode: 429,
        body: {'error': 'rate limited'},
        retryAfterSeconds: 12,
      );
      expect(
        localizeApiException(es, errRate),
        'Hiciste demasiados intentos. Espera un momento y vuelve a intentarlo.',
      );
      expect(
        localizeApiException(en, errRate),
        'Too many attempts. Wait a moment and try again.',
      );

      // 429 during live ingest must NEVER stop active tracking.
      expect(ingestLogRequiresStop('Upload response 429'), isFalse);
      expect(ingestLogIsRateLimited('Upload response 429'), isTrue);
      expect(ingestLogIndicatesFailure('Upload response 429'), isTrue);
    });

    testWidgets('multi-club account switches active club via POST /api/account/switch-club and can toggle Piloto público mode', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeClubSlugKey: 'club-a',
        PreferencesStore.activeClubNameKey: 'Club Alpha',
      });
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure(
        accountSessionId: 'acct-multi-sess',
        sessionId: 'club-a-sess',
        deviceToken: 'club_a_tok_0123456789abcdef0123456789',
        personalDeviceToken: 'pers_multi_tok_0123456789abcdef012345',
      );
      String? switchedMembershipId;
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-multi-sess',
        sessionId: 'club-a-sess',
        deviceToken: 'club_a_tok_0123456789abcdef0123456789',
        personalDeviceToken: 'pers_multi_tok_0123456789abcdef012345',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.accountSwitchClub) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            switchedMembershipId = body['membershipId'] as String?;
            return http.Response(
              jsonEncode({
                'ok': true,
                'pilotId': 'pilot-b',
                'clubId': 'cid-b',
                'activeMembershipId': switchedMembershipId,
                'club': {
                  'id': 'cid-b',
                  'slug': 'club-b',
                  'name': 'Club Bravo',
                },
              }),
              200,
              headers: {
                'set-cookie': 'fv_club_session=club-b-sess; Path=/',
              },
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final account = const AccountProfile(
        id: 'acct-multi',
        email: 'multi@club.cl',
        emailVerified: true,
        activeMembershipId: 'mem-a',
        memberships: [
          AccountMembership(
            id: 'mem-a',
            clubId: 'cid-a',
            slug: 'club-a',
            name: 'Club Alpha',
            role: 'pilot',
            status: 'active',
          ),
          AccountMembership(
            id: 'mem-b',
            clubId: 'cid-b',
            slug: 'club-b',
            name: 'Club Bravo',
            role: 'pilot',
            status: 'active',
          ),
        ],
      );
      final pilot = PilotProfile(
        id: 'pilot-a',
        name: 'Multi Pilot',
        email: 'multi@club.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: true,
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: HomeHubScreen(
            repo: repo,
            pilot: pilot,
            accountProfile: account,
            onStartFlight: (_, _) {},
            onRequestLogin: () {},
            onLogout: () {},
            onSwitchClub: (m) async {
              final res = await repo.client.switchClub(m.id);
              await repo.setActiveClub(slug: res.clubSlug, name: res.clubName);
            },
            permissions: _GrantedPermissions(),
            localFlightStore: InMemoryLocalFlightStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch club via bottom sheet.
      expect(find.byKey(FlightVisTestKeys.hubClubSwitchButton), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.hubClubSwitchButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.clubPickerOption('mem-b')));
      await tester.pumpAndSettle();

      expect(switchedMembershipId, 'mem-b');
      expect(client.sessionId, 'club-b-sess');
      expect(prefs.activeClubSlug(), 'club-b');
      expect(prefs.activeClubName(), 'Club Bravo');

      // Switch mode picker to "Piloto público" -> Iniciar vuelo opens PersonalFlightStartScreen without check-in.
      await tester.tap(find.byKey(FlightVisTestKeys.hubModePersonal));
      await tester.pumpAndSettle();
      expect(prefs.preferredFlightMode(), 'personal');

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();
      expect(find.byType(PersonalFlightStartScreen), findsOneWidget);
    });

    testWidgets('personal active tracking uses personal token, skips check-in expiry, and survives 429 without halting', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: 'flt-pers-track',
        PreferencesStore.activeFlightModeKey: 'personal',
        // Even an expired club check-in must NOT halt a personal flight!
        PreferencesStore.checkinExpiresAtKey: 1,
      });
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure(
        accountSessionId: 'acct-sess-t',
        deviceToken: 'club_tok_unused_0123456789abcdef012345',
        personalDeviceToken: 'personal_live_tok_0123456789abcdef0123',
      );
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess-t',
        deviceToken: 'club_tok_unused_0123456789abcdef012345',
        personalDeviceToken: 'personal_live_tok_0123456789abcdef0123',
        httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final tracker = _FakeTracker();
      final fixSource = InMemoryLocalFixSource();
      addTearDown(fixSource.dispose);
      final queue = InMemoryFixUploadQueueStore();
      var stopped = false;

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            repo: repo,
            flightId: 'flt-pers-track',
            tail: 'CC-PUB',
            flightMode: 'personal',
            tracking: TrackingService(tracker: tracker, fixSource: fixSource),
            uploadQueue: queue,
            onStopped: () => stopped = true,
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(stopped, isFalse);
      expect(tracker.started, isTrue);
      expect(
        tracker.lastConfig?.deviceId,
        'personal_live_tok_0123456789abcdef0123',
      );
      expect(tracker.lastConfig?.buffer, isFalse);

      // Simulate Traccar receiving HTTP 429 on /api/osmand.
      tracker.logs = [
        LogEntry(
          time: DateTime.now().millisecondsSinceEpoch + 1000,
          message: 'Upload response 429',
        ),
      ];
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // Active tracking stays alive and shows non-fatal rate-limit notice.
      expect(stopped, isFalse);
      expect(tracker.started, isTrue);
      expect(find.byKey(FlightVisTestKeys.trackingRateLimitBanner), findsOneWidget);
    });
  });

  group('Club flow unchanged', () {
    testWidgets('club member with valid check-in still opens TailPickerScreen and sends club flight without mode=personal', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.checkinExpiresAtKey:
            DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
        PreferencesStore.activeClubSlugKey: 'cas',
        PreferencesStore.activeClubNameKey: 'Club Aéreo',
      });
      final prefs = await PreferencesStore.open();
      final secure = _InMemorySecure(
        sessionId: 'club-sess',
        deviceToken: 'club_tok_0123456789abcdef0123456789012',
      );
      Map<String, dynamic>? startBody;
      String? startAuth;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        sessionId: 'club-sess',
        deviceToken: 'club_tok_0123456789abcdef0123456789012',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.meTails) {
            return http.Response(
              jsonEncode({
                'tails': [
                  {'id': 'a1', 'tail': 'CC-CLB', 'type_code': 'C172'},
                ],
              }),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.flights) {
            startBody = jsonDecode(request.body) as Map<String, dynamic>;
            startAuth = request.headers['Authorization'];
            return http.Response(
              jsonEncode({
                'id': 'flt-club-ok',
                'visibility': 'club',
                'showPilotNamePublic': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final clubPilot = PilotProfile(
        id: 'pilot-club',
        name: 'Club Pilot',
        email: 'club@cas.cl',
        status: 'approved',
        role: 'pilot',
        emailVerified: true,
      );

      String? startedId;
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: HomeHubScreen(
            repo: repo,
            pilot: clubPilot,
            onStartFlight: (id, _) => startedId = id,
            onRequestLogin: () {},
            onLogout: () {},
            permissions: _GrantedPermissions(),
            localFlightStore: InMemoryLocalFlightStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(FlightVisTestKeys.hubStartFlight));
      await tester.pumpAndSettle();

      expect(find.byType(TailPickerScreen), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.tailStart));
      await tester.pumpAndSettle();

      expect(startedId, 'flt-club-ok');
      expect(startBody?['tail'], 'CC-CLB');
      expect(startBody?['visibility'], 'club');
      expect(startBody?.containsKey('mode'), isFalse);
      expect(startAuth, 'Bearer club_tok_0123456789abcdef0123456789012');
    });
  });
}
