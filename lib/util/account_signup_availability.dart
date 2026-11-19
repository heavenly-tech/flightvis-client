import 'package:http/http.dart' as http;

import 'account_signup_url.dart';

typedef AccountSignupAvailabilityProbe = Future<bool> Function(String serverBaseUrl);

/// Whether the server's global sign-up page responds successfully (2xx).
abstract final class AccountSignupAvailability {
  static Future<bool> isAvailable(
    String serverBaseUrl, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = AccountSignupUrl.build(serverBaseUrl: serverBaseUrl);
    final owned = client == null;
    final httpClient = client ?? http.Client();
    try {
      var response = await httpClient.head(uri).timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      if (response.statusCode == 405 || response.statusCode == 404) {
        response = await httpClient.get(uri).timeout(timeout);
        return response.statusCode >= 200 && response.statusCode < 300;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      if (owned) {
        httpClient.close();
      }
    }
  }
}