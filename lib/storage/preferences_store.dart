import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';

class PreferencesStore {
  PreferencesStore(this._prefs);

  static const baseUrlKey = 'fv_base_url';
  static const checkinExpiresAtKey = 'fv_checkin_expires_at_ms';
  static const activeFlightIdKey = 'fv_active_flight_id';

  final SharedPreferences _prefs;

  static Future<PreferencesStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return PreferencesStore(prefs);
  }

  String baseUrl() {
    final saved = _prefs.getString(baseUrlKey);
    if (saved != null && saved.trim().isNotEmpty) {
      return AppConfig.normalizeBaseUrl(saved);
    }
    return AppConfig.normalizeBaseUrl(AppConfig.defaultBaseUrl);
  }

  Future<void> setBaseUrl(String url) =>
      _prefs.setString(baseUrlKey, AppConfig.normalizeBaseUrl(url));

  int? checkinExpiresAtMs() => _prefs.getInt(checkinExpiresAtKey);

  Future<void> setCheckinExpiresAtMs(int? expiresAt) async {
    if (expiresAt == null) {
      await _prefs.remove(checkinExpiresAtKey);
    } else {
      await _prefs.setInt(checkinExpiresAtKey, expiresAt);
    }
  }

  String? activeFlightId() => _prefs.getString(activeFlightIdKey);

  Future<void> setActiveFlightId(String? id) async {
    if (id == null) {
      await _prefs.remove(activeFlightIdKey);
    } else {
      await _prefs.setString(activeFlightIdKey, id);
    }
  }
}