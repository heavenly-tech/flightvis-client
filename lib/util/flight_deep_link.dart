/// `https://flight.heavenly.cl/c/{slug}/q/{token}` and club magic-link URLs.
class CheckinPayload {
  const CheckinPayload({required this.token, this.clubSlug});

  final String token;
  final String? clubSlug;
}

sealed class ParsedDeepLink {
  const ParsedDeepLink();
}

class CheckinDeepLink extends ParsedDeepLink {
  const CheckinDeepLink({required this.clubSlug, required this.token});

  final String clubSlug;
  final String token;
}

class MagicLinkDeepLink extends ParsedDeepLink {
  const MagicLinkDeepLink({required this.token});

  final String token;
}

/// `https://flight.heavenly.cl/app.html` — open the signed-in / guest home hub.
class AppHomeDeepLink extends ParsedDeepLink {
  const AppHomeDeepLink();
}

class FlightDeepLink {
  static const productionHost = 'flight.heavenly.cl';
  static const androidPackage = 'cl.heavenly.flightvis';

  /// Normalizes https VIEW intents and Chrome `intent://` fallback URLs (C-4: no untrusted extras).
  static ParsedDeepLink? parseIncoming(Uri uri, {Map<String, String>? extras}) {
    final https = _toHttps(uri);
    if (https == null) return null;
  if (!_isTrustedHost(https)) return null;
    final parsed = parseHttpsUri(https);
    if (parsed != null) return parsed;
    return _magicFromApiPath(https);
  }

  static ParsedDeepLink? parseUri(Uri uri) => parseIncoming(uri);

  static bool _isTrustedHost(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == productionHost || host.endsWith('.$productionHost');
  }

  static ParsedDeepLink? parseHttpsUri(Uri uri) {
    if (!_isTrustedHost(uri)) return null;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length == 1 && segs[0] == 'app.html') {
      return const AppHomeDeepLink();
    }
    if (segs.length >= 4 && segs[0] == 'c' && segs[2] == 'q') {
      final slug = segs[1];
      final token = Uri.decodeComponent(segs.sublist(3).join('/'));
      if (slug.isEmpty || token.isEmpty) return null;
      return CheckinDeepLink(clubSlug: slug, token: token);
    }
    if (segs.length >= 3 && segs[0] == 'auth' && segs[1] == 'magic') {
      final token = segs.sublist(2).join('/');
      if (token.isEmpty) return null;
      return MagicLinkDeepLink(token: Uri.decodeComponent(token));
    }
    return null;
  }

  static ParsedDeepLink? _magicFromApiPath(Uri uri) {
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length == 4 &&
        segs[0] == 'api' &&
        segs[1] == 'club' &&
        segs[2] == 'auth' &&
        segs[3] == 'magic') {
      final token = uri.queryParameters['token'];
      if (token != null && token.isNotEmpty) {
        return MagicLinkDeepLink(token: token);
      }
    }
    return null;
  }

  static Uri? _toHttps(Uri uri) {
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      return uri;
    }
    if (uri.scheme == 'intent') {
      return _intentFallbackToHttps(uri);
    }
    return null;
  }

  /// Chrome fallback: `intent://host/c/slug/q/token#Intent;scheme=https;package=…;end`
  static Uri? _intentFallbackToHttps(Uri intentUri) {
    final fragment = intentUri.fragment;
    if (!fragment.startsWith('Intent;')) return null;

    final scheme = _intentParam(fragment, 'scheme') ?? 'https';
    if (scheme != 'https' && scheme != 'http') return null;

    final hostParam = _intentParam(fragment, 'host');
    final host = hostParam ?? (intentUri.host.isNotEmpty ? intentUri.host : productionHost);
    if (host.isEmpty) return null;

    var path = intentUri.path;
    if (path.isEmpty && intentUri.host.isNotEmpty && intentUri.host.contains('/')) {
      path = '/${intentUri.host.substring(intentUri.host.indexOf('/'))}';
    }
    if (!path.startsWith('/')) path = '/$path';

    final pkg = _intentParam(fragment, 'package');
    if (pkg != null && pkg != androidPackage) return null;

    try {
      return Uri.parse('$scheme://$host$path');
    } catch (_) {
      return null;
    }
  }

  static String? _intentParam(String fragment, String key) {
    final match = RegExp('$key=([^;]+)').firstMatch(fragment);
    return match?.group(1);
  }

  /// QR scan or paste: HTTPS check-in URL, `intent://`, or raw rotating token.
  static CheckinPayload? parseCheckinScan(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      final link = parseIncoming(uri);
      if (link is CheckinDeepLink) {
        return CheckinPayload(token: link.token, clubSlug: link.clubSlug);
      }
    }
    return CheckinPayload(token: trimmed);
  }

  static String checkinUrl(String clubSlug, String token) =>
      'https://$productionHost/c/$clubSlug/q/${Uri.encodeComponent(token)}';
}