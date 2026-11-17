import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keystore-backed secrets: device bearer token and optional session id.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const deviceTokenKey = 'fv_device_token';
  static const sessionCookieKey = 'fv_club_session';

  final FlutterSecureStorage _storage;

  Future<String?> readDeviceToken() => _storage.read(key: deviceTokenKey);

  Future<void> writeDeviceToken(String token) =>
      _storage.write(key: deviceTokenKey, value: token.trim());

  Future<void> clearDeviceToken() => _storage.delete(key: deviceTokenKey);

  Future<String?> readSessionId() => _storage.read(key: sessionCookieKey);

  Future<void> writeSessionId(String sessionId) =>
      _storage.write(key: sessionCookieKey, value: sessionId.trim());

  Future<void> clearSessionId() => _storage.delete(key: sessionCookieKey);

  Future<void> clearAll() async {
    await clearDeviceToken();
    await clearSessionId();
  }
}