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

  test('map public radius defaults to 20 km, persists, and clamps/snaps out-of-range values', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.open();
    expect(store.mapPublicRadiusKm(), 20);

    await store.setMapPublicRadiusKm(50);
    final reloaded = await PreferencesStore.open();
    expect(reloaded.mapPublicRadiusKm(), 50);

    // Out-of-range and non-option stored values clamp to 5..500 and snap to
    // the nearest discrete option in [5, 10, 20, 50, 100, 200, 500].
    final cases = <int, int>{
      -20: 5,
      0: 5,
      4: 5,
      5: 5,
      7: 5,
      8: 10,
      10: 10,
      25: 20,
      40: 50,
      75: 50,
      80: 100,
      140: 100,
      160: 200,
      340: 200,
      360: 500,
      500: 500,
      9999: 500,
    };
    for (final entry in cases.entries) {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.mapPublicRadiusKmKey: entry.key,
      });
      final s = await PreferencesStore.open();
      expect(
        s.mapPublicRadiusKm(),
        entry.value,
        reason: 'stored=${entry.key} should normalize to ${entry.value}',
      );
      expect(PreferencesStore.publicRadiusKmOptions, contains(s.mapPublicRadiusKm()));
      expect(s.mapPublicRadiusKm(), inInclusiveRange(5, 500));
    }

    // setMapPublicRadiusKm also normalizes before persisting.
    SharedPreferences.setMockInitialValues({});
    final normStore = await PreferencesStore.open();
    await normStore.setMapPublicRadiusKm(999);
    final normReloaded = await PreferencesStore.open();
    expect(normReloaded.mapPublicRadiusKm(), 500);
  });

  test('persists legacy flights resolved marker, claimant bucket, and kept-on-phone guest IDs', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PreferencesStore.open();

    expect(store.legacyFlightsResolved(), isFalse);
    expect(store.legacyFlightsClaimantBucket(), isNull);
    expect(store.keptOnPhoneGuestFlightIds('acct_aaa'), isEmpty);

    expect(
      () => store.setLegacyFlightsClaimantBucket('guest'),
      throwsArgumentError,
    );
    expect(
      () => store.setLegacyFlightsClaimantBucket('legacy'),
      throwsArgumentError,
    );
    expect(
      () => store.setLegacyFlightsClaimantBucket('LEGACY'),
      throwsArgumentError,
    );

    await store.setLegacyFlightsClaimantBucket('acct_0123456789abcdef');
    await store.setLegacyFlightsResolved(true);
    await store.markGuestFlightsKeptOnPhone('acct_0123456789abcdef', ['g1', 'g2']);
    await store.markGuestFlightsKeptOnPhone('guest', ['should-ignore']);
    await store.markGuestFlightsKeptOnPhone('legacy', ['should-ignore']);

    final reloaded = await PreferencesStore.open();
    expect(reloaded.legacyFlightsClaimantBucket(), 'acct_0123456789abcdef');
    expect(reloaded.legacyFlightsResolved(), isTrue);
    expect(
      reloaded.keptOnPhoneGuestFlightIds('acct_0123456789abcdef'),
      {'g1', 'g2'},
    );
    expect(reloaded.keptOnPhoneGuestFlightIds('acct_other'), isEmpty);
    expect(reloaded.keptOnPhoneGuestFlightIds('guest'), isEmpty);
    expect(reloaded.keptOnPhoneGuestFlightIds('legacy'), isEmpty);
  });
}