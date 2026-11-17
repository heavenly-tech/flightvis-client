/// `https://flight.heavenly.cl/c/{slug}/q/{token}` and magic-link paths.
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

class FlightDeepLink {
  static const productionHost = 'flight.heavenly.cl';
  static const androidPackage = 'cl.heavenly.flightvis';

  /// Normalizes https VIEW intents, Chrome `intent://` fallback URLs, and [extras].
  static ParsedDeepLink? parseIncoming(Uri uri, {Map<String, String>? extras}) {
    final fromExtras = _fromExtras(extras);
    if (fromExtras != null) return fromExtras;

    final https = _toHttps(uri);
    if (https == null) return null;
    return parseHttpsUri(https);
  }

  static ParsedDeepLink? parseUri(Uri uri) => parseIncoming(uri);

  static ParsedDeepLink? parseHttpsUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host != productionHost && !host.endsWith('.$productionHost')) {
      return null;
    }
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
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

  static ParsedDeepLink? _fromExtras(Map<String, String>? extras) {
    if (extras == null || extras.isEmpty) return null;
    final token = extras['token'] ?? extras['checkin_token'] ?? extras['checkinToken'];
    final slug = extras['slug'] ?? extras['club_slug'] ?? extras['clubSlug'];
    if (token != null && token.isNotEmpty && slug != null && slug.isNotEmpty) {
      return CheckinDeepLink(clubSlug: slug, token: token);
    }
    final magic = extras['magic_token'] ?? extras['magicToken'];
    if (magic != null && magic.isNotEmpty) {
      return MagicLinkDeepLink(token: magic);
    }
    return null;
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