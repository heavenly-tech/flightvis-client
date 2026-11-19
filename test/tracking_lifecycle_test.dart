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

    test('true when server check unknown but check-in valid (M-5)', () {
      expect(
        shouldResumeTracking(
          activeFlightId: 'f1',
          serverSaysActive: null,
          checkinExpiresAtMs: 9_999_999,
          nowMs: 0,
        ),
        isTrue,
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
    test('stops on Upload response 400, 401, 403', () {
      expect(ingestLogRequiresStop('Upload response 400'), isTrue);
      expect(ingestLogRequiresStop('Upload response 401'), isTrue);
      expect(ingestLogRequiresStop('Upload response 403'), isTrue);
    });

    test('does not stop on 200 or 500', () {
      expect(ingestLogRequiresStop('Upload response 200'), isFalse);
      expect(ingestLogRequiresStop('Upload response 500'), isFalse);
    });

    test('coordinate line containing 401 does not stop', () {
      expect(
        ingestLogRequiresStop('position lat=-33.4012 lon=-70.6'),
        isFalse,
      );
    });

    test('ignores unrelated logs', () {
      expect(ingestLogRequiresStop('position sent ok'), isFalse);
      expect(ingestLogRequiresStop('upload unauthorized'), isFalse);
    });
  });
}