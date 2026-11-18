import '../app_config.dart';

/// Club-scoped web pilot registration (browser). Path may move when server PR #19 lands.
abstract final class ClubRegistrationUrl {
  static const defaultClubSlug = 'cas';

  /// When `false`, use `/c/{slug}/register` instead of legacy `club-register.html`.
  static const useLegacyHtmlPath = true;

  static String resolveClubSlug({
    String? activeClubSlug,
    String? clientClubSlug,
  }) {
    for (final candidate in [activeClubSlug, clientClubSlug]) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return defaultClubSlug;
  }

  static Uri build({
    required String serverBaseUrl,
    required String clubSlug,
  }) {
    final root = AppConfig.normalizeBaseUrl(serverBaseUrl);
  final slug = Uri.encodeComponent(clubSlug);
    if (useLegacyHtmlPath) {
      return Uri.parse('$root/club-register.html?club=$slug');
    }
    return Uri.parse('$root/c/$slug/register');
  }
}