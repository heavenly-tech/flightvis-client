import 'package:flutter_test/flutter_test.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/services/tracking_log_cursor.dart';
import 'package:flight_vis/services/tracking_session.dart';

class _FakeTraccarClientSdk extends Fake implements TraccarClientSdk {
  List<LogEntry> logs = [];

  @override
  Future<List<LogEntry>> getLogs() async => List<LogEntry>.from(logs);
}

void main() {
  group('logEntriesAfter', () {
    test('detects Upload response after 5000-line rotation (M-3)', () {
      final rotated = <LogEntry>[
        for (var i = 2; i <= 5000; i++) LogEntry(time: i, message: 'pos'),
        LogEntry(time: 5001, message: 'Upload response 401'),
      ];
      expect(
        ingestStopInEntries(logEntriesAfter(rotated, 5000)),
        isTrue,
      );
    });

    test('old Upload response 400 ignored after watermark at tail (M-4)', () {
      final logs = [
        LogEntry(time: 100, message: 'Upload response 400'),
        LogEntry(time: 200, message: 'tracking ok'),
      ];
      expect(ingestStopInEntries(logEntriesAfter(logs, 200)), isFalse);
    });
  });

  group('TrackingSession', () {
    test('syncCursorFromExistingLogs then poll ignores prior tail', () async {
      final fake = _FakeTraccarClientSdk()
        ..logs = [
          LogEntry(time: 10, message: 'Upload response 400'),
          LogEntry(time: 20, message: 'idle'),
        ];
      final session = TrackingSession(tracker: fake);
      await session.syncCursorFromExistingLogs();
      expect(await session.pollIngestRequiresStop(), isFalse);
      fake.logs.add(LogEntry(time: 30, message: 'Upload response 403'));
      expect(await session.pollIngestRequiresStop(), isTrue);
    });
  });
}