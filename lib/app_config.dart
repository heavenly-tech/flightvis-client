/// Build-time and runtime server base URL configuration.
class AppConfig {
  static const defaultBaseUrl = String.fromEnvironment(
    'FLIGHTVIS_BASE_URL',
    defaultValue: 'https://flight.heavenly.cl',
  );

  /// Default club check-in validity (minutes) when the server does not return it.
  static const defaultCheckinValidMinutes = 30;

  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static String osmandUrl(String baseUrl) => '${normalizeBaseUrl(baseUrl)}/api/osmand';
}