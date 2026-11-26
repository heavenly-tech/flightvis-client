import 'dart:async';
import 'dart:convert';

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
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

import 'helpers/fake_tile_provider.dart';

const _deviceToken = '01234567890123456789012345678901';
const _flightUuid = '550e8400-e29b-41d4-a716-446655440000';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => _deviceToken;
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
  int stopCalls = 0;

  @override
  Future<void> init(Config config) async {}

  @override
  Future<void> setConfig(Config config) async {}

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
  Future<List<LogEntry>> getLogs() async => const [];
}

Future<AppRepository> _buildRepo({
  http.Client? httpClient,
  String? sessionId,
  int? activeTrailMinutes,
  int? clubTrailDefault,
}) async {
  SharedPreferences.setMockInitialValues({
    PreferencesStore.activeFlightIdKey: _flightUuid,
    PreferencesStore.checkinExpiresAtKey:
        DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
    if (activeTrailMinutes != null)
      PreferencesStore.activeFlightTrailMinutesKey: activeTrailMinutes,
    if (clubTrailDefault != null)
      PreferencesStore.clubTrailMinutesDefaultKey: clubTrailDefault,
  });
  final prefs = await PreferencesStore.open();
  return AppRepository(
    secure: _FakeSecure(),
    prefs: prefs,
    client: FlightVisClient(
      baseUrl: prefs.baseUrl(),
      httpClient: httpClient,
      deviceToken: _deviceToken,
      sessionId: sessionId,
    ),
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

  testWidgets('hides raw flightId UUID and shows end-flight confirmation on stop', (tester) async {
    var endFlightCalls = 0;
    final repo = await _buildRepo(
      sessionId: 'sess-1',
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/api/flights/$_flightUuid/end') {
          endFlightCalls++;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();
    var stopped = false;

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () => stopped = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Raw flightId UUID must never be shown visibly.
    expect(find.textContaining(_flightUuid), findsNothing);
    expect(find.textContaining('550e8400'), findsNothing);
    expect(find.text('Matrícula: CC-ABC'), findsOneWidget);
    expect(find.text('Finalizar seguimiento'), findsOneWidget);
    expect(tracker.started, isTrue);

    // Tapping Stop opens confirmation dialog (no history dialog).
    await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
    await tester.pumpAndSettle();

    expect(find.text('¿Finalizar el seguimiento de CC-ABC?'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('Finalizar'), findsOneWidget);
    expect(find.textContaining('historial'), findsNothing);

    // Tapping Cancelar keeps tracking running.
    await tester.tap(find.byKey(FlightVisTestKeys.trackingStopCancel));
    await tester.pumpAndSettle();

    expect(endFlightCalls, 0);
    expect(tracker.stopCalls, 0);
    expect(stopped, isFalse);
    expect(repo.prefs.activeFlightId(), _flightUuid);

    // Tapping Stop then Finalizar stops tracking, calls endFlight, clears activeFlightId, invokes onStopped.
    await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FlightVisTestKeys.trackingStopConfirm));
    await tester.pumpAndSettle();

    expect(endFlightCalls, 1);
    expect(tracker.stopCalls, 1);
    expect(stopped, isTrue);
    expect(repo.prefs.activeFlightId(), isNull);
  });

  testWidgets('guest user also gets end-flight confirmation and 409/404 completes stop', (tester) async {
    var endFlightCalls = 0;
    final repo = await _buildRepo(
      sessionId: null,
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/api/flights/$_flightUuid/end') {
          endFlightCalls++;
          return http.Response(jsonEncode({'error': 'already ended'}), 409);
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();
    var stopped = false;

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('en'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'N12345',
          tracking: TrackingService(tracker: tracker),
          onStopped: () => stopped = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(_flightUuid), findsNothing);

    await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
    await tester.pumpAndSettle();

    expect(find.text('Finish tracking N12345?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);

    await tester.tap(find.byKey(FlightVisTestKeys.trackingStopConfirm));
    await tester.pumpAndSettle();

    expect(endFlightCalls, 1);
    expect(tracker.stopCalls, 1);
    expect(stopped, isTrue);
    expect(repo.prefs.activeFlightId(), isNull);
  });

  testWidgets('restores persisted trail selection, PATCHes on change, and persists update', (tester) async {
    final patchBodies = <Map<String, dynamic>>[];
    String? patchAuth;
    String? patchCookie;
    final repo = await _buildRepo(
      sessionId: 'sess-trail',
      activeTrailMinutes: 10,
      clubTrailDefault: 5,
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path == '/api/flights/$_flightUuid/trail') {
          patchAuth = request.headers['Authorization'];
          patchCookie = request.headers['Cookie'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          patchBodies.add(body);
          return http.Response(
            jsonEncode({'trailMinutes': body['trailMinutes']}),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/api/flights/$_flightUuid/end') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Estela en el mapa'), findsOneWidget);
    expect(find.text('Usar predeterminado del club (5 min)'), findsOneWidget);
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(10))).selected,
      isTrue,
    );

    // Change to Todo (-1).
    await tester.tap(find.byKey(FlightVisTestKeys.trailChip(-1)));
    await tester.pumpAndSettle();

    expect(patchBodies, [{'trailMinutes': -1}]);
    expect(patchAuth, 'Bearer $_deviceToken');
    expect(patchCookie, 'fv_club_session=sess-trail');
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(-1))).selected,
      isTrue,
    );
    expect(repo.prefs.activeFlightTrailMinutes(), -1);

    // Change back to club default (null).
    await tester.tap(find.byKey(FlightVisTestKeys.trailChip(null)));
    await tester.pumpAndSettle();

    expect(patchBodies, [
      {'trailMinutes': -1},
      {'trailMinutes': null},
    ]);
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(null))).selected,
      isTrue,
    );
    expect(repo.prefs.activeFlightTrailMinutes(), isNull);
  });

  testWidgets('optimistically selects trail chip, reverts and shows SnackBar on PATCH failure', (tester) async {
    final completer = Completer<http.Response>();
    final repo = await _buildRepo(
      sessionId: 'sess-trail',
      activeTrailMinutes: 5,
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path == '/api/flights/$_flightUuid/trail') {
          return completer.future;
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(5))).selected,
      isTrue,
    );

    // Tap 30 min -> optimistically selected while PATCH is in flight.
    await tester.tap(find.byKey(FlightVisTestKeys.trailChip(30)));
    await tester.pump();
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(30))).selected,
      isTrue,
    );

    // Server rejects with 403 -> reverts to 5 and shows localized SnackBar.
    completer.complete(http.Response(jsonEncode({'error': 'forbidden'}), 403));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(5))).selected,
      isTrue,
    );
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(30))).selected,
      isFalse,
    );
    expect(repo.prefs.activeFlightTrailMinutes(), 5);
    expect(
      find.text('No pudimos cambiar la estela. Inténtalo de nuevo.'),
      findsOneWidget,
    );
  });

  testWidgets('treats 409 on trail PATCH as no-op without error SnackBar', (tester) async {
    final repo = await _buildRepo(
      sessionId: 'sess-trail',
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path == '/api/flights/$_flightUuid/trail') {
          return http.Response(jsonEncode({'error': 'not active'}), 409);
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(FlightVisTestKeys.trailChip(0)));
    await tester.pumpAndSettle();

    expect(
      find.text('No pudimos cambiar la estela. Inténtalo de nuevo.'),
      findsNothing,
    );
    expect(
      tester.widget<ChoiceChip>(find.byKey(FlightVisTestKeys.trailChip(0))).selected,
      isTrue,
    );
  });

  testWidgets('ending flight clears persisted activeFlightTrailMinutes', (tester) async {
    final repo = await _buildRepo(
      sessionId: 'sess-1',
      activeTrailMinutes: 15,
      httpClient: http_testing.MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/api/flights/$_flightUuid/end') {
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final tracker = _FakeTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.prefs.activeFlightTrailMinutes(), 15);

    await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FlightVisTestKeys.trackingStopConfirm));
    await tester.pumpAndSettle();

    expect(repo.prefs.activeFlightId(), isNull);
    expect(repo.prefs.activeFlightTrailMinutes(), isNull);
  });

  testWidgets('wraps body in SingleChildScrollView with no overflow on small screen and Stop reachable', (tester) async {
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repo = await _buildRepo(
      sessionId: 'sess-1',
      clubTrailDefault: 5,
      httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
    );
    final tracker = _FakeTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: tracker),
          onStopped: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(FlightVisTestKeys.trackingStop));
    await tester.pumpAndSettle();
    expect(find.byKey(FlightVisTestKeys.trackingStop), findsOneWidget);
  });

  testWidgets('surfaces localized error when Traccar SDK start() throws instead of failing silently', (tester) async {
    final repo = await _buildRepo(
      sessionId: 'sess-1',
      httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
    );
    final failingTracker = _ThrowingTracker();

    await tester.pumpWidget(
      PilotAppShell(
        locale: const Locale('es', 'CL'),
        home: TrackingScreen(
          repo: repo,
          flightId: _flightUuid,
          tail: 'CC-ABC',
          tracking: TrackingService(tracker: failingTracker),
          onStopped: () {},
          enableMapPolling: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No se pudo iniciar el GPS. Revisa los permisos de ubicación.'),
      findsOneWidget,
    );
    expect(find.text('Transmisión pausada'), findsOneWidget);
  });
}

class _ThrowingTracker extends _FakeTracker {
  @override
  Future<void> start() async {
    throw PlatformException(code: 'gps_denied', message: 'Denied by OS');
  }
}
