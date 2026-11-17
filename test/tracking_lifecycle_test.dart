import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/services/tracking_lifecycle.dart';

void main() {
  group('shouldResumeTracking', () {
    test('false when no active flight', () {
      expect(
        shouldResumeTracking(
          activeFlightId: null,
          serverSaysActive: true,
          checkinExpiresAtMs: null,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('false when server says inactive', () {
      expect(
        shouldResumeTracking(
          activeFlightId: 'f1',
          serverSaysActive: false,
          checkinExpiresAtMs: 9_999_999,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('false when server check failed (null)', () {
      expect(
        shouldResumeTracking(
          activeFlightId: 'f1',
          serverSaysActive: null,
          checkinExpiresAtMs: 9_999_999,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('false when check-in expired', () {
      expect(
        shouldResumeTracking(
          activeFlightId: 'f1',
          serverSaysActive: true,
          checkinExpiresAtMs: 1000,
          nowMs: 1000,
        ),
        isFalse,
      );
    });

    test('true when flight active and check-in valid', () {
      expect(
        shouldResumeTracking(
          activeFlightId: 'f1',
          serverSaysActive: true,
          checkinExpiresAtMs: 5_000,
          nowMs: 1_000,
        ),
        isTrue,
      );
    });
  });

  group('ingestLogRequiresStop', () {
    test('401 and unauthorized', () {
      expect(ingestLogRequiresStop('HTTP 401 from /api/osmand'), isTrue);
      expect(ingestLogRequiresStop('upload unauthorized'), isTrue);
    });

    test('400 no active flight', () {
      expect(ingestLogRequiresStop('HTTP 400: no active flight'), isTrue);
    });

    test('ignores unrelated logs', () {
      expect(ingestLogRequiresStop('position sent ok'), isFalse);
    });
  });
}