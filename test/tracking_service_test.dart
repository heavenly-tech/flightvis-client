import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/services/tracking_service.dart';

class _FakeTraccarClientSdk extends Fake implements TraccarClientSdk {
  bool started = false;

  @override
  Future<void> init(Config config) async {}

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
}