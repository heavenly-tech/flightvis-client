import '../app_config.dart';

/// Global pilot account sign-up in the external browser.
///
/// TODO(global-accounts): Replace browser `/signup` with in-app magic-link
/// sign-up once the server account API (post server PR #19) is available.
abstract final class AccountSignupUrl {
  static const relativePath = '/signup';

  static Uri build({required String serverBaseUrl}) {
    final root = AppConfig.normalizeBaseUrl(serverBaseUrl);
    return Uri.parse('$root$relativePath');
  }
}