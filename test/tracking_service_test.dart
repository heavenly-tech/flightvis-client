import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/services/tracking_service.dart';

class _FakeTraccarClientSdk extends Fake implements TraccarClientSdk {
  bool started = false;
  final List<Config> initCalls = [];
  final List<Config> setConfigCalls = [];

  @override
  Future<void> init(Config config) async {
    initCalls.add(config);
  }

  @override
  Future<void> setConfig(Config config) async {
    setConfigCalls.add(config);
  }

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isTracking() async => started;

  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start succeeds when expiry alarm channel throws PlatformException (HIGH)', () async {
    const channel = MethodChannel('cl.heavenly.flightvis/tracking');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scheduleCheckinExpiryStop') {
        throw PlatformException(code: 'exact_alarms_not_permitted');
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final fake = _FakeTraccarClientSdk();
    final tracking = TrackingService(tracker: fake);
    await tracking.initForFlight(
      baseUrl: 'https://flight.heavenly.cl',
      deviceToken: '01234567890123456789012345678901',
      checkinExpiresAtMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    final ok = await tracking.start();
    expect(ok, isTrue);
    expect(fake.started, isTrue);
  });

  test('initForFlight passes trimmed device token to /api/osmand via init and setConfig', () async {
    final fake = _FakeTraccarClientSdk();
    final tracking = TrackingService(tracker: fake);
    const firstToken = 'tok_first_012345678901234567890123456789';
    const rotatedToken = 'tok_rotated_9876543210987654321098765432';

    await tracking.initForFlight(
      baseUrl: 'https://flight.heavenly.cl/',
      deviceToken: '  $firstToken  ',
    );
    expect(fake.initCalls.single.serverUrl, 'https://flight.heavenly.cl/api/osmand');
    expect(fake.initCalls.single.deviceId, firstToken);
    expect(fake.setConfigCalls.single.deviceId, firstToken);

    await tracking.initForFlight(
      baseUrl: 'https://flight.heavenly.cl',
      deviceToken: rotatedToken,
    );
    expect(fake.setConfigCalls.last.deviceId, rotatedToken);
    expect(fake.setConfigCalls.last.serverUrl, 'https://flight.heavenly.cl/api/osmand');
  });

  test('initForFlight rejects empty device token', () async {
    final fake = _FakeTraccarClientSdk();
    final tracking = TrackingService(tracker: fake);
    await expectLater(
      tracking.initForFlight(
        baseUrl: 'https://flight.heavenly.cl',
        deviceToken: '   ',
      ),
      throwsArgumentError,
    );
    expect(fake.initCalls, isEmpty);
    expect(fake.setConfigCalls, isEmpty);
  });

  test('start returns false and does not throw when Traccar SDK start() throws', () async {
    final throwingTracker = _ThrowingStartTracker();
    final tracking = TrackingService(tracker: throwingTracker);
    await tracking.initForFlight(
      baseUrl: 'https://flight.heavenly.cl',
      deviceToken: '01234567890123456789012345678901',
    );
    final ok = await tracking.start();
    expect(ok, isFalse);
  });
}

class _ThrowingStartTracker extends _FakeTraccarClientSdk {
  @override
  Future<void> start() async {
    throw PlatformException(code: 'gps_error', message: 'Location provider disabled');
  }
}