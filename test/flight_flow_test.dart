import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/state/checkin_gate.dart';

/// Start-flight gate: mirrors tail picker behaviour without HTTP.
void main() {
  test('server rejection message shown when start blocked', () {
    final gate = CheckinGate(expiresAtMs: null, nowMs: 0);
    final reason = gate.startBlockedReason();
    expect(reason, isNotNull);
    expect(reason, isNot(contains('expired')));
  });

  test('expired check-in reason', () {
    final gate = CheckinGate(expiresAtMs: 100, nowMs: 200);
    expect(gate.startBlockedReason(), contains('expired'));
  });
}