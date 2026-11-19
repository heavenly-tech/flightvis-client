import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/checkin_expiry_format.dart';

void main() {
  setUpAll(CheckinExpiryFormat.ensureInitialized);

  tearDown(() => CheckinExpiryFormat.nowUtcOverride = null);

  test('formats same-day as time only', () {
    CheckinExpiryFormat.nowUtcOverride = DateTime.utc(2026, 11, 17, 18, 0);
    final expires = DateTime.utc(2026, 11, 17, 20, 0);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, '17:00');
  });

  test('formats other day with date and time', () {
    CheckinExpiryFormat.nowUtcOverride = DateTime.utc(2026, 11, 17, 18, 0);
    final expires = DateTime.utc(2026, 11, 20, 15, 30);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, '20/11/2026 12:30');
  });

  test('same-day boundary is evaluated in America/Santiago', () {
    // Expiry and “now” share a Santiago calendar day though UTC crosses midnight.
    CheckinExpiryFormat.nowUtcOverride = DateTime.utc(2026, 11, 17, 21, 0);
    final expires = DateTime.utc(2026, 11, 18, 2, 0);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, '23:00');
  });

  test('different Santiago calendar day shows date even when UTC is close', () {
    CheckinExpiryFormat.nowUtcOverride = DateTime.utc(2026, 11, 18, 2, 0);
    final expires = DateTime.utc(2026, 11, 18, 5, 0);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, '18/11/2026 02:00');
  });

  test('far-future now still formats deterministically', () {
    CheckinExpiryFormat.nowUtcOverride = DateTime.utc(2099, 6, 15, 12, 0);
    final expires = DateTime.utc(2099, 6, 15, 18, 45);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, '15:45');
  });
}