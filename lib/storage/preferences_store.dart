import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../dev/dev_tools_gate.dart';
import '../services/locale_preferences.dart';
import 'local_flight_store.dart';

class PreferencesStore {
  PreferencesStore(this._prefs);

  static const baseUrlKey = 'fv_base_url';
  static const checkinExpiresAtKey = 'fv_checkin_expires_at_ms';
  static const activeFlightIdKey = 'fv_active_flight_id';
  static const activeFlightModeKey = 'fv_active_flight_mode';
  static const activeFlightTailKey = 'fv_active_flight_tail';
  static const activeFlightTrailMinutesKey = 'fv_active_flight_trail_minutes';
  static const preferredFlightModeKey = 'fv_preferred_flight_mode';
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
  static const cachedPilotProfileKey = 'fv_cached_pilot_profile';
  static const cachedAccountProfileKey = 'fv_cached_account_profile';
  static const legacyFlightsResolvedKey = 'fv_legacy_flights_resolved';
  static const legacyFlightsClaimantBucketKey =
      'fv_legacy_flights_claimant_bucket';
  static const guestFlightsKeptOnPhoneKey = 'fv_guest_flights_kept_on_phone';

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
      await _prefs.remove(activeFlightModeKey);
      await _prefs.remove(activeFlightTailKey);
      await _prefs.remove(activeFlightTrailMinutesKey);
    } else {
      await _prefs.setString(activeFlightIdKey, id);
    }
  }

  /// Active broadcast flight mode (`'club'` or `'personal'`). Defaults to `'club'`.
  String activeFlightMode() =>
      _prefs.getString(activeFlightModeKey) == 'personal' ? 'personal' : 'club';

  Future<void> setActiveFlightMode(String? mode) async {
    if (mode == null || mode.isEmpty) {
      await _prefs.remove(activeFlightModeKey);
    } else {
      await _prefs.setString(activeFlightModeKey, mode);
    }
  }

  String? activeFlightTail() => _prefs.getString(activeFlightTailKey);

  Future<void> setActiveFlightTail(String? tail) async {
    if (tail == null || tail.isEmpty) {
      await _prefs.remove(activeFlightTailKey);
    } else {
      await _prefs.setString(activeFlightTailKey, tail);
    }
  }

  /// Last user-selected hub broadcast mode (`'club'` or `'personal'`).
  String? preferredFlightMode() => _prefs.getString(preferredFlightModeKey);

  Future<void> setPreferredFlightMode(String? mode) async {
    if (mode == null || mode.isEmpty) {
      await _prefs.remove(preferredFlightModeKey);
    } else {
      await _prefs.setString(preferredFlightModeKey, mode);
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

  /// Cached last verified pilot profile so transient offline startups do not
  /// sign out the user while `/api/club/me` is unreachable.
  PilotProfile? cachedPilotProfile() {
    final raw = _prefs.getString(cachedPilotProfileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return PilotProfile.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setCachedPilotProfile(PilotProfile? profile) async {
    if (profile == null) {
      await _prefs.remove(cachedPilotProfileKey);
    } else {
      await _prefs.setString(cachedPilotProfileKey, jsonEncode(profile.toJson()));
    }
  }

  /// Cached last verified global account profile for offline startups.
  AccountProfile? cachedAccountProfile() {
    final raw = _prefs.getString(cachedAccountProfileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AccountProfile.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setCachedAccountProfile(AccountProfile? profile) async {
    if (profile == null) {
      await _prefs.remove(cachedAccountProfileKey);
    } else {
      await _prefs.setString(
        cachedAccountProfileKey,
        jsonEncode(profile.toJson()),
      );
    }
  }

  /// True once the first signed-in account has resolved the one-time legacy
  /// local-flights choice (adopted or deleted). Persists across restarts so no
  /// other account or guest is ever offered legacy files.
  bool legacyFlightsResolved() =>
      _prefs.getBool(legacyFlightsResolvedKey) ?? false;

  Future<void> setLegacyFlightsResolved(bool value) =>
      _prefs.setBool(legacyFlightsResolvedKey, value);

  /// Hashed account bucket ID (`acct_<hex>`) of the first account offered the
  /// legacy local-flights choice. When that account dismisses without deciding,
  /// only this bucket is offered the choice again.
  String? legacyFlightsClaimantBucket() {
    final raw = _prefs.getString(legacyFlightsClaimantBucketKey)?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (LocalFlightStore.isReservedBucket(raw)) return null;
    final sanitized = LocalFlightStore.sanitizeBucket(raw);
    if (sanitized == LocalFlightStore.guestBucket) return null;
    return sanitized;
  }

  Future<void> setLegacyFlightsClaimantBucket(String? bucket) async {
    final trimmed = bucket?.trim() ?? '';
    if (trimmed.isEmpty) {
      await _prefs.remove(legacyFlightsClaimantBucketKey);
      return;
    }
    if (LocalFlightStore.isReservedBucket(trimmed)) {
      throw ArgumentError.value(
        bucket,
        'bucket',
        'Reserved bucket cannot claim legacy flights',
      );
    }
    final sanitized = LocalFlightStore.sanitizeBucket(trimmed);
    if (sanitized == LocalFlightStore.guestBucket) {
      throw ArgumentError.value(
        bucket,
        'bucket',
        'Guest bucket cannot claim legacy flights',
      );
    }
    await _prefs.setString(legacyFlightsClaimantBucketKey, sanitized);
  }

  Map<String, Set<String>> _readGuestFlightsKeptMap() {
    final raw = _prefs.getString(guestFlightsKeptOnPhoneKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, Set<String>>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is List) {
          out[entry.key] = value.whereType<String>().toSet();
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Guest flight IDs that [accountBucket] explicitly chose to leave on this
  /// phone ("Dejarlos en este teléfono"), persisted across sessions/reopens.
  Set<String> keptOnPhoneGuestFlightIds(String accountBucket) {
    if (LocalFlightStore.isReservedBucket(accountBucket)) return const {};
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);
    if (sanitized == LocalFlightStore.guestBucket) return const {};
    final map = _readGuestFlightsKeptMap();
    return Set<String>.unmodifiable(map[sanitized] ?? const <String>{});
  }

  Future<void> markGuestFlightsKeptOnPhone(
    String accountBucket,
    Iterable<String> flightIds,
  ) async {
    if (LocalFlightStore.isReservedBucket(accountBucket)) return;
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);
    if (sanitized == LocalFlightStore.guestBucket) return;
    final cleanedIds = flightIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (cleanedIds.isEmpty) return;
    final map = _readGuestFlightsKeptMap();
    final existing = map.putIfAbsent(sanitized, () => <String>{});
    existing.addAll(cleanedIds);
    final encoded = <String, List<String>>{
      for (final entry in map.entries)
        entry.key: (entry.value.toList()..sort()),
    };
    await _prefs.setString(guestFlightsKeptOnPhoneKey, jsonEncode(encoded));
  }
}