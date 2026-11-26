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

  test('persists active flight trail minutes and clears when active flight ends', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.open();

    expect(store.activeFlightTrailMinutes(), isNull);
    await store.setActiveFlightId('f-1');
    await store.setActiveFlightTrailMinutes(0);
    expect(store.activeFlightTrailMinutes(), 0);
    await store.setActiveFlightTrailMinutes(-1);
    expect(store.activeFlightTrailMinutes(), -1);
    await store.setActiveFlightTrailMinutes(15);
    expect(store.activeFlightTrailMinutes(), 15);

    await store.setActiveFlightId(null);
    expect(store.activeFlightId(), isNull);
    expect(store.activeFlightTrailMinutes(), isNull);

    await store.setClubTrailMinutesDefault(5);
    expect(store.clubTrailMinutesDefault(), 5);
    await store.setClubTrailMinutesDefault(null);
    expect(store.clubTrailMinutesDefault(), isNull);
  });

  test('map layer defaults (own/club ON, public OFF) and persistence', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.open();

    expect(store.mapLayerOwn(), isTrue);
    expect(store.mapLayerClub(), isTrue);
    expect(store.mapLayerPublic(), isFalse);

    await store.setMapLayerOwn(false);
    await store.setMapLayerClub(false);
    await store.setMapLayerPublic(true);

    final reloaded = await PreferencesStore.open();
    expect(reloaded.mapLayerOwn(), isFalse);
    expect(reloaded.mapLayerClub(), isFalse);
    expect(reloaded.mapLayerPublic(), isTrue);
  });
}