import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/services/tracking_lifecycle.dart';

/// Documents restore path: when resume is false, callers must invoke [TrackingService.stop].
void main() {
  test('restore clears stale flight when server inactive', () {
    expect(
      shouldResumeTracking(
        activeFlightId: 'flight-1',
        serverSaysActive: false,
        checkinExpiresAtMs: null,
        nowMs: 0,
      ),
      isFalse,
    );
  });

  test('restore skips tracking when check-in expired', () {
    expect(
      shouldResumeTracking(
        activeFlightId: 'flight-1',
        serverSaysActive: true,
        checkinExpiresAtMs: 100,
        nowMs: 200,
      ),
      isFalse,
    );
  });
}