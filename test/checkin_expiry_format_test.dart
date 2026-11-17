import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/checkin_expiry_format.dart';

void main() {
  setUpAll(CheckinExpiryFormat.ensureInitialized);

  test('formats same-day as time only', () {
    final nowClub = DateTime.utc(2026, 11, 17, 18, 0);
    final expires = nowClub.add(const Duration(hours: 2));
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, matches(RegExp(r'^\d{1,2}:\d{2}$')));
  });

  test('formats other day with date and time', () {
    final expires = DateTime.utc(2026, 11, 20, 15, 30);
    final label = CheckinExpiryFormat.formatFromUtc(expires);
    expect(label, contains('20'));
    expect(label, contains(':'));
  });
}