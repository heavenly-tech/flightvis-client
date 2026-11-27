import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';

import '../api/flight_vis_client.dart';
import 'device_install_id.dart';
import '../services/locale_preferences.dart';
import '../storage/preferences_store.dart';
import '../storage/secure_store.dart';

typedef InstallIdProvider = Future<String> Function();
typedef DeviceModelProvider = Future<String?> Function();

/// Wires HTTP client, secure storage, and preferences.
class AppRepository {
  AppRepository({
    required this.secure,
    required this.prefs,
    required this.client,
    InstallIdProvider? installIdProvider,
    DeviceModelProvider? deviceModelProvider,
    DateTime Function()? clock,
  })  : _installIdProvider = installIdProvider ?? DeviceInstallId.getOrCreate,
        _deviceModelProvider = deviceModelProvider ?? _defaultDeviceModel,
        _clock = clock ?? DateTime.now;

  final SecureStore secure;
  final PreferencesStore prefs;
  final FlightVisClient client;
  final InstallIdProvider _installIdProvider;
  final DeviceModelProvider _deviceModelProvider;
  final DateTime Function() _clock;

  int nowMs() => _clock().millisecondsSinceEpoch;

  LocalePreferences get localePrefs => prefs.locale;

  static Future<String?> _defaultDeviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      final android = await info.androidInfo;
      final model = android.model.trim();
      return model.isEmpty ? null : model;
    } catch (_) {
      return null;
    }
  }

  Future<String> readInstallId() => _installIdProvider();

  Future<String?> readDeviceModel() => _deviceModelProvider();

  static Future<AppRepository> create({
    SecureStore? secure,
    PreferencesStore? prefs,
    FlightVisClient? client,
  }) async {
    final secureStore = secure ?? SecureStore();
    final preferences = prefs ?? await PreferencesStore.open();
    final sessionId = await secureStore.readSessionId();
    final accountSessionId = await secureStore.readAccountSessionId();
    final deviceToken = await secureStore.readDeviceToken();
    final personalDeviceToken = await secureStore.readPersonalDeviceToken();
    final api = client ??
        FlightVisClient(
          baseUrl: preferences.baseUrl(),
          sessionId: sessionId,
          accountSessionId: accountSessionId,
          deviceToken: deviceToken,
          personalDeviceToken: personalDeviceToken,
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
    final acctId = client.accountSessionId;
    if (acctId == null) {
      await secure.clearAccountSessionId();
    } else {
      await secure.writeAccountSessionId(acctId);
    }
  }

  Future<void> persistDeviceToken(String token) async {
    await secure.writeDeviceToken(token);
    client.setDeviceToken(token);
  }

  Future<void> persistPersonalDeviceToken(String token) async {
    await secure.writePersonalDeviceToken(token);
    client.setPersonalDeviceToken(token);
  }

  /// Clears `fv_personal_device_token` from secure storage and memory (M-31).
  Future<void> clearPersonalDeviceToken() async {
    await secure.clearPersonalDeviceToken();
    client.setPersonalDeviceToken(null);
  }

  /// Clears `fv_personal_device_token` whenever the signed-in account id
  /// changes (M-31), and persists [newAccountId] as the active account id.
  /// Returns `true` when an account switch was detected and the token cleared.
  Future<bool> clearPersonalDeviceTokenIfAccountChanged(
    String newAccountId,
  ) async {
    final normalized = newAccountId.trim();
    if (normalized.isEmpty) return false;
    final previous = (prefs.lastSignedInAccountId() ??
            prefs.cachedAccountProfile()?.id ??
            prefs.cachedPilotProfile()?.id)
        ?.trim();
    final changed =
        previous != null && previous.isNotEmpty && previous != normalized;
    if (changed) {
      await clearPersonalDeviceToken();
    }
    await prefs.setLastSignedInAccountId(normalized);
    return changed;
  }

  Future<String?> readDeviceTokenForMode(String flightMode) async {
    if (flightMode == 'personal') {
      final inMem = client.personalDeviceToken?.trim();
      if (inMem != null && inMem.isNotEmpty) return inMem;
      final stored = (await secure.readPersonalDeviceToken())?.trim();
      if (stored != null && stored.isNotEmpty) {
        client.setPersonalDeviceToken(stored);
        return stored;
      }
      return null;
    }
    final inMem = client.deviceToken?.trim();
    if (inMem != null && inMem.isNotEmpty) return inMem;
    final stored = (await secure.readDeviceToken())?.trim();
    if (stored != null && stored.isNotEmpty) {
      client.setDeviceToken(stored);
      return stored;
    }
    return null;
  }

  void refreshBaseUrl() {
    client.baseUrl = prefs.baseUrl();
  }

  /// Ensures a club device bearer token exists when a session is active.
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
    if (!client.hasAccountSession) {
      final storedAcct = (await secure.readAccountSessionId())?.trim();
      if (storedAcct != null && storedAcct.isNotEmpty) {
        client.setAccountSessionId(storedAcct);
      }
    }
    if (!client.hasAnySession) return;
    final reg = await client.registerDevice(
      installId: await _installIdProvider(),
      model: await _deviceModelProvider(),
    );
    if (reg != null && reg.token.isNotEmpty) {
      await persistDeviceToken(reg.token);
    }
  }

  /// Ensures a personal (club-less) device bearer token exists via
  /// `POST /api/account/devices {mode: "personal"}` without overwriting any
  /// club device token.
  Future<String> ensurePersonalDeviceRegistered() async {
    final inMem = client.personalDeviceToken?.trim();
    if (inMem != null && inMem.length >= 32) {
      return inMem;
    }
    final existing = (await secure.readPersonalDeviceToken())?.trim();
    if (existing != null && existing.length >= 32) {
      client.setPersonalDeviceToken(existing);
      return existing;
    }
    if (!client.hasAccountSession) {
      final storedAcct = (await secure.readAccountSessionId())?.trim();
      if (storedAcct != null && storedAcct.isNotEmpty) {
        client.setAccountSessionId(storedAcct);
      }
    }
    final reg = await client.registerAccountDevice(
      mode: 'personal',
      installId: await _installIdProvider(),
      label: 'Android',
      model: await _deviceModelProvider(),
    );
    await persistPersonalDeviceToken(reg.token);
    return reg.token;
  }

  /// Submits a rotating QR (`v1.…`) or browser-landing handoff/claim (`h1.…`)
  /// token to `POST /api/checkin`.
  ///
  /// For a first-scan guest with no session and no device token:
  /// 1. Opens an anonymous guest session via `POST /api/devices/anonymous`.
  /// 2. Posts the token to `POST /api/checkin` with the guest session cookie.
  /// 3. Persists the server-issued device token (`result.deviceToken`, never
  ///    the raw `deviceId`) so tracking sends `id=<deviceToken>` to `/api/osmand`.
  /// 4. Also handles E1 multi-club check-ins where the server mints/reuses a
  ///    target-club device token without rebinding the old club or personal device.
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
    if (!client.hasAccountSession) {
      final storedAcct = (await secure.readAccountSessionId())?.trim();
      if (storedAcct != null && storedAcct.isNotEmpty) {
        client.setAccountSessionId(storedAcct);
      }
    }
    if (!client.hasDeviceToken && !client.hasAnySession) {
      await client.startGuestSession(name: 'Android');
      await persistSession();
    }
    String? installId;
    String? model;
    if (client.hasAccountSession) {
      try {
        installId = await _installIdProvider();
      } catch (_) {}
      model = await _deviceModelProvider();
    }
    final result = await client.checkin(
      token,
      clubSlug: clubSlug,
      installId: installId,
      label: installId != null ? 'Android' : null,
      model: model,
    );
    final issuedToken = result.deviceToken?.trim();
    if (issuedToken != null && issuedToken.isNotEmpty) {
      await persistDeviceToken(issuedToken);
    } else if (!client.hasDeviceToken && client.hasAnySession) {
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