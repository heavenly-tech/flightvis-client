import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keystore-backed secrets: club/personal device bearer tokens and session ids.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _usesDefaultStorage = storage == null,
        _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  static const deviceTokenKey = 'fv_device_token';
  static const personalDeviceTokenKey = 'fv_personal_device_token';
  static const sessionCookieKey = 'fv_club_session';
  static const accountSessionCookieKey = 'fv_account_session';

  final bool _usesDefaultStorage;
  final FlutterSecureStorage _storage;
  final Map<String, String> _subclassMemory = {};

  /// Legacy test fakes (`class _FakeSecure extends SecureStore`) often override
  /// only `readDeviceToken`/`readSessionId` without supplying a backing
  /// [FlutterSecureStorage]. Avoid invoking the real platform channel from
  /// unoverridden subclass methods during widget tests.
  bool get _useSubclassMemory =>
      _usesDefaultStorage && runtimeType != SecureStore;

  Future<String?> readDeviceToken() => _storage.read(key: deviceTokenKey);

  Future<void> writeDeviceToken(String token) =>
      _storage.write(key: deviceTokenKey, value: token.trim());

  Future<void> clearDeviceToken() => _storage.delete(key: deviceTokenKey);

  Future<String?> readPersonalDeviceToken() async {
    if (_useSubclassMemory) return _subclassMemory[personalDeviceTokenKey];
    return _storage.read(key: personalDeviceTokenKey);
  }

  Future<void> writePersonalDeviceToken(String token) async {
    if (_useSubclassMemory) {
      _subclassMemory[personalDeviceTokenKey] = token.trim();
      return;
    }
    await _storage.write(key: personalDeviceTokenKey, value: token.trim());
  }

  Future<void> clearPersonalDeviceToken() async {
    if (_useSubclassMemory) {
      _subclassMemory.remove(personalDeviceTokenKey);
      return;
    }
    await _storage.delete(key: personalDeviceTokenKey);
  }

  Future<String?> readSessionId() => _storage.read(key: sessionCookieKey);

  Future<void> writeSessionId(String sessionId) =>
      _storage.write(key: sessionCookieKey, value: sessionId.trim());

  Future<void> clearSessionId() => _storage.delete(key: sessionCookieKey);

  Future<String?> readAccountSessionId() async {
    if (_useSubclassMemory) return _subclassMemory[accountSessionCookieKey];
    return _storage.read(key: accountSessionCookieKey);
  }

  Future<void> writeAccountSessionId(String sessionId) async {
    if (_useSubclassMemory) {
      _subclassMemory[accountSessionCookieKey] = sessionId.trim();
      return;
    }
    await _storage.write(
      key: accountSessionCookieKey,
      value: sessionId.trim(),
    );
  }

  Future<void> clearAccountSessionId() async {
    if (_useSubclassMemory) {
      _subclassMemory.remove(accountSessionCookieKey);
      return;
    }
    await _storage.delete(key: accountSessionCookieKey);
  }

  Future<void> clearAll() async {
    await clearDeviceToken();
    await clearPersonalDeviceToken();
    await clearSessionId();
    await clearAccountSessionId();
  }
}