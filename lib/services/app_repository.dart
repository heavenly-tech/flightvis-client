import '../api/flight_vis_client.dart';
import '../storage/preferences_store.dart';
import '../storage/secure_store.dart';

/// Wires HTTP client, secure storage, and preferences.
class AppRepository {
  AppRepository({
    required this.secure,
    required this.prefs,
    required this.client,
  });

  final SecureStore secure;
  final PreferencesStore prefs;
  final FlightVisClient client;

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
    return AppRepository(secure: secureStore, prefs: preferences, client: api);
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

  /// Ensures a bearer token exists (anonymous guest device by default).
  Future<void> ensureDeviceRegistered({bool preferPilotRegistration = false}) async {
    final existing = await secure.readDeviceToken();
    if (existing != null && existing.length >= 32) {
      client.setDeviceToken(existing);
      return;
    }
    final reg = preferPilotRegistration && client.sessionId != null
        ? await client.registerDevice()
        : await client.registerAnonymousDevice();
    await persistDeviceToken(reg.token);
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