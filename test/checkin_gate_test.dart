import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/state/checkin_gate.dart';

void main() {
  final now = 1_700_000_000_000;

  test('no check-in blocks start', () {
    final gate = CheckinGate(expiresAtMs: null, nowMs: now);
    expect(gate.canStartFlight, isFalse);
    expect(gate.startBlock(), CheckinStartBlock.missing);
  });

  test('expired check-in blocks start', () {
    final gate = CheckinGate(expiresAtMs: now - 1, nowMs: now);
    expect(gate.canStartFlight, isFalse);
    expect(gate.startBlock(), CheckinStartBlock.expired);
  });

  test('valid check-in allows start', () {
    final gate = CheckinGate(expiresAtMs: now + 60_000, nowMs: now);
    expect(gate.canStartFlight, isTrue);
    expect(gate.remaining()?.inSeconds, 60);
  });
}