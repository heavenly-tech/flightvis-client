import 'package:flutter/widgets.dart';

import '../api/flight_vis_client.dart';
import 'device_install_id.dart';
import '../services/locale_preferences.dart';
import '../storage/preferences_store.dart';
import '../storage/secure_store.dart';

typedef InstallIdProvider = Future<String> Function();

/// Wires HTTP client, secure storage, and preferences.
class AppRepository {
  AppRepository({
    required this.secure,
    required this.prefs,
    required this.client,
    InstallIdProvider? installIdProvider,
  }) : _installIdProvider = installIdProvider ?? DeviceInstallId.getOrCreate;

  final SecureStore secure;
  final PreferencesStore prefs;
  final FlightVisClient client;
  final InstallIdProvider _installIdProvider;

  LocalePreferences get localePrefs => prefs.locale;

  static Future<AppRepository> create({
    SecureStore? secure,
    PreferencesStore? prefs,
    FlightVisClient? client,
  }) async {
    final secureStore = secure ?? SecureStore();
    final preferences = prefs ?? await PreferencesStore.open();
    final sessionId = await secureStore.readSessionId();
    final deviceToken = await secureStore.readDeviceToken();
    final api = client ??
        FlightVisClient(
          baseUrl: preferences.baseUrl(),
          sessionId: sessionId,
          deviceToken: deviceToken,
          clubSlug: preferences.activeClubSlug(),
        );
    final repo = AppRepository(secure: secureStore, prefs: preferences, client: api);
    final device = WidgetsBinding.instance.platformDispatcher.locale;
    final resolved = repo.localePrefs.resolveLocale(device);
    repo.client.setAcceptLanguage(repo.localePrefs.apiLocaleTag(resolved));
    return repo;
  }

  void syncApiLocale(Locale locale) {
    client.setAcceptLanguage(localePrefs.apiLocaleTag(locale));
  }

  void syncClubFromPrefs() {
    client.setClubSlug(prefs.activeClubSlug());
  }

  Future<void> setActiveClub({required String slug, String? name}) async {
    await prefs.setActiveClub(slug: slug, name: name);
    client.setClubSlug(slug);
  }

  Future<void> persistSession() async {
    final id = client.sessionId;
    if (id == null) {
      await secure.clearSessionId();
    } else {
      await secure.writeSessionId(id);
    }
  }

  Future<void> persistDeviceToken(String token) async {
    await secure.writeDeviceToken(token);
    client.setDeviceToken(token);
  }

  void refreshBaseUrl() {
    client.baseUrl = prefs.baseUrl();
  }

  /// Ensures a device bearer token exists when a session is active.
  ///
  /// When there is no session, skips `POST /api/me/devices` so anonymous/guest
  /// startup never triggers or surfaces a 401.
  Future<void> ensureDeviceRegistered({bool preferPilotRegistration = false}) async {
    final existing = (await secure.readDeviceToken())?.trim();
    if (existing != null && existing.length >= 32) {
      client.setDeviceToken(existing);
      return;
    }
    if (!client.hasSession) {
      final storedSession = (await secure.readSessionId())?.trim();
      if (storedSession != null && storedSession.isNotEmpty) {
        client.setSessionId(storedSession);
      }
    }
    if (!client.hasSession) return;
    final reg = await client.registerDevice(
      installId: await _installIdProvider(),
    );
    if (reg != null && reg.token.isNotEmpty) {
      await persistDeviceToken(reg.token);
    }
  }

  /// Submits a rotating QR (`v1.…`) or browser-landing handoff/claim (`h1.…`)
  /// token to `POST /api/checkin`.
  ///
  /// For a first-scan guest with no session and no device token:
  /// 1. Opens an anonymous guest session via `POST /api/devices/anonymous`.
  /// 2. Posts the token to `POST /api/checkin` with the guest session cookie.
  /// 3. Persists the server-issued device token (`result.deviceToken`, never
  ///    the raw `deviceId`) so tracking sends `id=<deviceToken>` to `/api/osmand`.
  /// 4. If the server omitted `token` on check-in and no device token is stored
  ///    yet, falls back to `POST /api/me/devices` with the guest session cookie
  ///    without surfacing 401 / `ignored: true` errors.
  Future<CheckinResult> submitCheckin(
    String token, {
    String? clubSlug,
  }) async {
    syncClubFromPrefs();
    if (!client.hasDeviceToken) {
      final storedToken = (await secure.readDeviceToken())?.trim();
      if (storedToken != null && storedToken.isNotEmpty) {
        client.setDeviceToken(storedToken);
      }
    }
    if (!client.hasSession) {
      final storedSession = (await secure.readSessionId())?.trim();
      if (storedSession != null && storedSession.isNotEmpty) {
        client.setSessionId(storedSession);
      }
    }
    if (!client.hasDeviceToken && !client.hasSession) {
      await client.startGuestSession(name: 'Android');
      await persistSession();
    }
    final result = await client.checkin(token, clubSlug: clubSlug);
    final issuedToken = result.deviceToken?.trim();
    if (issuedToken != null && issuedToken.isNotEmpty) {
      await persistDeviceToken(issuedToken);
    } else if (!client.hasDeviceToken && client.hasSession) {
      try {
        await ensureDeviceRegistered();
      } catch (_) {}
    }
    final expiresMs = result.expiresAtEpochMs();
    await prefs.setCheckinExpiresAtMs(expiresMs);
    await applyCheckinClub(result, fallbackSlug: clubSlug);
    return result;
  }

  Future<void> applyCheckinClub(CheckinResult result, {String? fallbackSlug}) async {
    final slug = result.clubSlug ?? fallbackSlug;
    var name = result.clubName;
    if (slug != null) {
      if (name == null || name.isEmpty) {
        try {
          name = (await client.fetchClub(slug)).name;
        } catch (_) {
          name = slug;
        }
      }
      await setActiveClub(slug: slug, name: name);
    }
  }
}