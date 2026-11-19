import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/storage/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists device token keys and check-in expiry', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.open();
    expect(store.baseUrl(), contains('flight.heavenly'));
    await store.setBaseUrl('https://club.example');
    // Tests run in debug/profile (not release); override is honored.
    expect(store.baseUrl(), 'https://club.example');
    await store.setCheckinExpiresAtMs(999);
    expect(store.checkinExpiresAtMs(), 999);
    await store.setCheckinExpiresAtMs(null);
    expect(store.checkinExpiresAtMs(), isNull);
  });
}