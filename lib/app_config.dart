/// Build-time and runtime server base URL configuration.
class AppConfig {
  static const defaultBaseUrl = String.fromEnvironment(
    'FLIGHTVIS_BASE_URL',
    defaultValue: 'https://flight.heavenly.cl',
  );

  /// Fallback when the server omits `expiresAt` (club-configured; not shown in UI).
  static const defaultCheckinValidMinutes = 12 * 60;

  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static String osmandUrl(String baseUrl) => '${normalizeBaseUrl(baseUrl)}/api/osmand';
}