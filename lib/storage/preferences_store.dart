import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import '../services/locale_preferences.dart';

class PreferencesStore {
  PreferencesStore(this._prefs);

  static const baseUrlKey = 'fv_base_url';
  static const checkinExpiresAtKey = 'fv_checkin_expires_at_ms';
  static const activeFlightIdKey = 'fv_active_flight_id';
  static const permissionsOnboardingKey = 'fv_permissions_onboarding_done';
  static const activeClubSlugKey = 'fv_active_club_slug';
  static const activeClubNameKey = 'fv_active_club_name';
  static const pendingCheckinSlugKey = 'fv_pending_checkin_slug';
  static const pendingCheckinTokenKey = 'fv_pending_checkin_token';

  final SharedPreferences _prefs;

  LocalePreferences get locale => LocalePreferences(_prefs);

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

  String? pendingCheckinSlug() => _prefs.getString(pendingCheckinSlugKey);

  String? pendingCheckinToken() => _prefs.getString(pendingCheckinTokenKey);

  Future<void> setPendingCheckin({String? slug, String? token}) async {
    if (slug == null || slug.isEmpty) {
      await _prefs.remove(pendingCheckinSlugKey);
    } else {
      await _prefs.setString(pendingCheckinSlugKey, slug);
    }
    if (token == null || token.isEmpty) {
      await _prefs.remove(pendingCheckinTokenKey);
    } else {
      await _prefs.setString(pendingCheckinTokenKey, token);
    }
  }

  Future<void> clearPendingCheckin() => setPendingCheckin(slug: null, token: null);

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