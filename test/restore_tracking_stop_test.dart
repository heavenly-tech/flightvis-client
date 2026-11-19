import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/services/tracking_lifecycle.dart';

/// L-33: when [stopStickyTrackerOnRestore] is true, main.dart calls SDK stop whenever
/// [shouldResumeTracking] is false (including no active-flight pref — START_STICKY).
bool restoreMustStopSdk({
  required bool resumeTracking,
  required bool stopStickyTrackerOnRestore,
}) =>
    stopStickyTrackerOnRestore && !resumeTracking;

const _validCheckin = 9_999_999;
const _flightId = 'f1';

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
        activeFlightId: _flightId,
        serverSaysActive: true,
        checkinExpiresAtMs: 100,
        nowMs: 200,
      );
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isTrue);
    });

    test('server inactive requires stop', () {
      final resume = shouldResumeTracking(
        activeFlightId: _flightId,
        serverSaysActive: false,
        checkinExpiresAtMs: _validCheckin,
        nowMs: 0,
      );
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isTrue);
    });
  });

  group('M-5 unknown server must not end flight', () {
    test('network error keeps flight (unknown → resume, pref kept)', () {
      final unknown = serverFlightActiveFromError(
        FlightVisException('socket', statusCode: null),
      );
      expect(unknown, isNull);
      final resume = shouldResumeTracking(
        activeFlightId: _flightId,
        serverSaysActive: unknown,
        checkinExpiresAtMs: _validCheckin,
        nowMs: 0,
      );
      expect(resume, isTrue);
      expect(restoreMustStopSdk(resumeTracking: resume, stopStickyTrackerOnRestore: true), isFalse);
    });

    test('timeout keeps flight (503 treated as unknown)', () {
      final unknown = serverFlightActiveFromError(
        FlightVisException('timeout', statusCode: 503),
      );
      expect(unknown, isNull);
      expect(
        shouldResumeTracking(
          activeFlightId: _flightId,
          serverSaysActive: unknown,
          checkinExpiresAtMs: _validCheckin,
          nowMs: 0,
        ),
        isTrue,
      );
    });

    test('explicit 404 stops flight', () {
      final ended = serverFlightActiveFromError(
        FlightVisException('not found', statusCode: 404),
      );
      expect(ended, isFalse);
      expect(
        shouldResumeTracking(
          activeFlightId: _flightId,
          serverSaysActive: ended,
          checkinExpiresAtMs: _validCheckin,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('explicit 409 stops flight', () {
      final ended = serverFlightActiveFromError(
        FlightVisException('conflict', statusCode: 409),
      );
      expect(ended, isFalse);
      expect(
        shouldResumeTracking(
          activeFlightId: _flightId,
          serverSaysActive: ended,
          checkinExpiresAtMs: _validCheckin,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('server reports flight ended (inactive list) stops flight', () {
      expect(
        shouldResumeTracking(
          activeFlightId: _flightId,
          serverSaysActive: false,
          checkinExpiresAtMs: _validCheckin,
          nowMs: 0,
        ),
        isFalse,
      );
    });

    test('expired check-in stops despite unknown server', () {
      expect(
        shouldResumeTracking(
          activeFlightId: _flightId,
          serverSaysActive: null,
          checkinExpiresAtMs: 50,
          nowMs: 100,
        ),
        isFalse,
      );
    });
  });
}