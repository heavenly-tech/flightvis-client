import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';

class PreferencesStore {
  PreferencesStore(this._prefs);

  static const baseUrlKey = 'fv_base_url';
  static const checkinExpiresAtKey = 'fv_checkin_expires_at_ms';
  static const activeFlightIdKey = 'fv_active_flight_id';
  static const permissionsOnboardingKey = 'fv_permissions_onboarding_done';
  static const activeClubSlugKey = 'fv_active_club_slug';
  static const activeClubNameKey = 'fv_active_club_name';

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

  bool permissionsOnboardingComplete() =>
      _prefs.getBool(permissionsOnboardingKey) ?? false;

  Future<void> setPermissionsOnboardingComplete(bool value) =>
      _prefs.setBool(permissionsOnboardingKey, value);

  Future<void> setActiveFlightId(String? id) async {
    if (id == null) {
      await _prefs.remove(activeFlightIdKey);
    } else {
      await _prefs.setString(activeFlightIdKey, id);
    }
  }

  String? activeClubSlug() => _prefs.getString(activeClubSlugKey);

  String? activeClubName() => _prefs.getString(activeClubNameKey);

  Future<void> setActiveClub({String? slug, String? name}) async {
    if (slug == null || slug.isEmpty) {
      await _prefs.remove(activeClubSlugKey);
    } else {
      await _prefs.setString(activeClubSlugKey, slug);
    }
    if (name == null || name.isEmpty) {
      await _prefs.remove(activeClubNameKey);
    } else {
      await _prefs.setString(activeClubNameKey, name);
    }
  }
}