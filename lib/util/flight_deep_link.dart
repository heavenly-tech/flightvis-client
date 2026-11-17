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

  static ParsedDeepLink? parseUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host != productionHost && !host.endsWith('.$productionHost')) {
      return null;
    }
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length >= 4 && segs[0] == 'c' && segs[2] == 'q') {
      final slug = segs[1];
      final token = Uri.decodeComponent(segs[3]);
      if (slug.isEmpty || token.isEmpty) return null;
      return CheckinDeepLink(clubSlug: slug, token: token);
    }
    if (segs.length == 3 && segs[0] == 'auth' && segs[1] == 'magic') {
      final token = segs[2];
      if (token.isEmpty) return null;
      return MagicLinkDeepLink(token: token);
    }
    return null;
  }

  /// QR scan or paste: HTTPS check-in URL, or raw rotating token.
  static CheckinPayload? parseCheckinScan(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final link = parseUri(uri);
      if (link is CheckinDeepLink) {
        return CheckinPayload(token: link.token, clubSlug: link.clubSlug);
      }
    }
    return CheckinPayload(token: trimmed);
  }

  static String checkinUrl(String clubSlug, String token) =>
      'https://$productionHost/c/$clubSlug/q/${Uri.encodeComponent(token)}';
}