import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

class _InMemoryPlatformSecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storage key constants are stable across 1.2.0+3 -> 1.4.0+5', () {
    expect(SecureStore.deviceTokenKey, 'fv_device_token');
    expect(SecureStore.sessionCookieKey, 'fv_club_session');
  });

  test('session id and device token survive reopening AppRepository', () async {
    SharedPreferences.setMockInitialValues({});
    final backingStorage = _InMemoryPlatformSecureStorage();
    final secure1 = SecureStore(storage: backingStorage);
    final prefs1 = await PreferencesStore.open();

    final repo1 = await AppRepository.create(secure: secure1, prefs: prefs1);
    repo1.client.setSessionId('sess-persisted-140');
    await repo1.persistSession();
    await repo1.persistDeviceToken('tok_persisted_0123456789abcdef0123456789');

    expect(backingStorage.data['fv_club_session'], 'sess-persisted-140');
    expect(
      backingStorage.data['fv_device_token'],
      'tok_persisted_0123456789abcdef0123456789',
    );

    // Reopen fresh SecureStore + PreferencesStore + AppRepository on the same backing store.
    final secure2 = SecureStore(storage: backingStorage);
    final prefs2 = await PreferencesStore.open();
    final repo2 = await AppRepository.create(secure: secure2, prefs: prefs2);

    expect(repo2.client.sessionId, 'sess-persisted-140');
    expect(repo2.client.deviceToken, 'tok_persisted_0123456789abcdef0123456789');
    expect(repo2.client.hasSession, isTrue);
    expect(repo2.client.hasDeviceToken, isTrue);
  });
}
