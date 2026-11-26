import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import '../dev/dev_tools_gate.dart';
import '../services/locale_preferences.dart';

class PreferencesStore {
  PreferencesStore(this._prefs);

  static const baseUrlKey = 'fv_base_url';
  static const checkinExpiresAtKey = 'fv_checkin_expires_at_ms';
  static const activeFlightIdKey = 'fv_active_flight_id';
  static const activeFlightTrailMinutesKey = 'fv_active_flight_trail_minutes';
  static const clubTrailMinutesDefaultKey = 'fv_club_trail_minutes_default';
  static const mapLayerOwnKey = 'fv_map_layer_own';
  static const mapLayerClubKey = 'fv_map_layer_club';
  static const mapLayerPublicKey = 'fv_map_layer_public';
  static const mapPublicRadiusKmKey = 'fv_map_public_radius_km';
  static const permissionsOnboardingKey = 'fv_permissions_onboarding_done';

  /// Discrete pilot-selectable radii (km) for the Público map layer, matching
  /// the server's `5..500` clamp and `20` km default.
  static const List<int> publicRadiusKmOptions = [5, 10, 20, 50, 100, 200, 500];
  static const int defaultPublicRadiusKm = 20;
  static const int minPublicRadiusKm = 5;
  static const int maxPublicRadiusKm = 500;

  /// Clamps [raw] into `5..500` and snaps to the nearest allowed option in
  /// [publicRadiusKmOptions] (defaults to [defaultPublicRadiusKm] when `null`).
  static int normalizePublicRadiusKm(int? raw) {
    if (raw == null) return defaultPublicRadiusKm;
    final clamped = raw.clamp(minPublicRadiusKm, maxPublicRadiusKm);
    var best = publicRadiusKmOptions.first;
    var bestDiff = (clamped - best).abs();
    for (final option in publicRadiusKmOptions.skip(1)) {
      final diff = (clamped - option).abs();
      if (diff < bestDiff) {
        best = option;
        bestDiff = diff;
      }
    }
    return best;
  }
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

  /// Effective API base URL (persisted override only in non-release builds).
  static String effectiveBaseUrl({required String? saved, required bool releaseMode}) {
    if (!releaseMode && saved != null && saved.trim().isNotEmpty) {
      return AppConfig.normalizeBaseUrl(saved);
    }
    return AppConfig.normalizeBaseUrl(AppConfig.defaultBaseUrl);
  }

  String baseUrl() {
    return effectiveBaseUrl(saved: _prefs.getString(baseUrlKey), releaseMode: !hiddenServerSettingsEnabled);
  }

  Future<void> setBaseUrl(String url) async {
    if (!hiddenServerSettingsEnabled) return;
    await _prefs.setString(baseUrlKey, AppConfig.normalizeBaseUrl(url));
  }

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
      await _prefs.remove(activeFlightTrailMinutesKey);
    } else {
      await _prefs.setString(activeFlightIdKey, id);
    }
  }

  int? activeFlightTrailMinutes() => _prefs.getInt(activeFlightTrailMinutesKey);

  Future<void> setActiveFlightTrailMinutes(int? minutes) async {
    if (minutes == null) {
      await _prefs.remove(activeFlightTrailMinutesKey);
    } else {
      await _prefs.setInt(activeFlightTrailMinutesKey, minutes);
    }
  }

  int? clubTrailMinutesDefault() => _prefs.getInt(clubTrailMinutesDefaultKey);

  Future<void> setClubTrailMinutesDefault(int? minutes) async {
    if (minutes == null) {
      await _prefs.remove(clubTrailMinutesDefaultKey);
    } else {
      await _prefs.setInt(clubTrailMinutesDefaultKey, minutes);
    }
  }

  /// Map layer toggle: own live trail/marker (default: ON).
  bool mapLayerOwn() => _prefs.getBool(mapLayerOwnKey) ?? true;

  Future<void> setMapLayerOwn(bool value) =>
      _prefs.setBool(mapLayerOwnKey, value);

  /// Map layer toggle: club aircraft (default: ON).
  bool mapLayerClub() => _prefs.getBool(mapLayerClubKey) ?? true;

  Future<void> setMapLayerClub(bool value) =>
      _prefs.setBool(mapLayerClubKey, value);

  /// Map layer toggle: public aircraft (default: OFF).
  bool mapLayerPublic() => _prefs.getBool(mapLayerPublicKey) ?? false;

  Future<void> setMapLayerPublic(bool value) =>
      _prefs.setBool(mapLayerPublicKey, value);

  /// Radius in km for the Público map layer (default: 20, clamped/snapped to
  /// [publicRadiusKmOptions] within `5..500`).
  int mapPublicRadiusKm() =>
      normalizePublicRadiusKm(_prefs.getInt(mapPublicRadiusKmKey));

  Future<void> setMapPublicRadiusKm(int radiusKm) => _prefs.setInt(
        mapPublicRadiusKmKey,
        normalizePublicRadiusKm(radiusKm),
      );

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