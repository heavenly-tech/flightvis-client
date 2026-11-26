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
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

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
}) async {
  SharedPreferences.setMockInitialValues({
    PreferencesStore.activeFlightIdKey: _flightUuid,
    PreferencesStore.checkinExpiresAtKey:
        DateTime.now().millisecondsSinceEpoch + 3600 * 1000,
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, (_) async => null);
  });

  tearDown(() {
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
}
