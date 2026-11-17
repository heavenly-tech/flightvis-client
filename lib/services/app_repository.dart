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
        );
    return AppRepository(secure: secureStore, prefs: preferences, client: api);
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
}