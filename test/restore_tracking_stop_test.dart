import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/services/tracking_lifecycle.dart';

/// L-33: when [stopStickyTrackerOnRestore] is true, main.dart calls SDK stop whenever
/// [shouldResumeTracking] is false (including no active-flight pref — START_STICKY).
bool restoreMustStopSdk({
  required bool resumeTracking,
  required bool stopStickyTrackerOnRestore,
}) =>
    stopStickyTrackerOnRestore && !resumeTracking;

void main() {
  group('L-33 sticky SDK stop on restore', () {
    test('no active flight still requires stop when resume is false', () {
      final resume = shouldResumeTracking(
        activeFlightId: null,
        serverSaysActive: null,
        checkinExpiresAtMs: null,
        nowMs: 0,
      );
      expect(resume, isFalse);
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isTrue);
    });

    test('expired check-in requires stop even if pref still set', () {
      final resume = shouldResumeTracking(
        activeFlightId: 'f1',
        serverSaysActive: true,
        checkinExpiresAtMs: 100,
        nowMs: 200,
      );
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isTrue);
    });

    test('server inactive requires stop', () {
      final resume = shouldResumeTracking(
        activeFlightId: 'f1',
        serverSaysActive: false,
        checkinExpiresAtMs: 9_999_999,
        nowMs: 0,
      );
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isTrue);
    });
  });
}