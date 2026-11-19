import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/services/checkin_expiry_alarm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cl.heavenly.flightvis/tracking');
  final log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('scheduleStopAt invokes native schedule with expiry ms', () async {
    final expiresAt = DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
    await CheckinExpiryAlarm.scheduleStopAt(expiresAt);
    expect(log, hasLength(1));
    expect(log.single.method, 'scheduleCheckinExpiryStop');
    expect(log.single.arguments, expiresAt);
  });

  test('scheduleStopAt cancels when expiry is in the past', () async {
    await CheckinExpiryAlarm.scheduleStopAt(1);
    expect(log.single.method, 'cancelCheckinExpiryStop');
  });

  test('stop cancel invokes native cancel', () async {
    await CheckinExpiryAlarm.cancel();
    expect(log.single.method, 'cancelCheckinExpiryStop');
  });
}