import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/storage/secure_store.dart';

void main() {
  test('storage key constants are stable', () {
    expect(SecureStore.deviceTokenKey, 'fv_device_token');
    expect(SecureStore.sessionCookieKey, 'fv_club_session');
  });
}