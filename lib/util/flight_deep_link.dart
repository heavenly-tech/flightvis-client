import 'dart:convert';

/// `https://flight.heavenly.cl/c/{slug}/q/{token}` and club magic-link URLs.
/// Supports both rotating kiosk QR tokens (`v1.…`) and single-use landing
/// handoff/claim tokens (`h1.…`).
class CheckinPayload {
  const CheckinPayload({required this.token, this.clubSlug});

  final String token;
  final String? clubSlug;

  bool get isClaimToken => FlightDeepLink.isClaimToken(token);
}

sealed class ParsedDeepLink {
  const ParsedDeepLink();
}

class CheckinDeepLink extends ParsedDeepLink {
  const CheckinDeepLink({required this.clubSlug, required this.token});

  final String clubSlug;
  final String token;

  bool get isClaimToken => FlightDeepLink.isClaimToken(token);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CheckinDeepLink &&
          other.clubSlug == clubSlug &&
          other.token == token;

  @override
  int get hashCode => Object.hash(clubSlug, token);
}

class MagicLinkDeepLink extends ParsedDeepLink {
  const MagicLinkDeepLink({required this.token});

  final String token;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MagicLinkDeepLink && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

/// `https://flight.heavenly.cl/api/account/auth/magic?token=...[&purpose=...][&email=...]`
/// — E1 account magic-link sign-in/signup/invite App Link.
class AccountMagicLinkDeepLink extends ParsedDeepLink {
  const AccountMagicLinkDeepLink({
    required this.token,
    this.purpose,
    this.email,
  });

  final String token;
  final String? purpose;

  /// Optional email extracted from the link query parameter or JWT token
  /// claims when present (never used for confirm UI copy — see M-33).
  final String? email;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountMagicLinkDeepLink &&
          other.token == token &&
          other.purpose == purpose &&
          other.email == email;

  @override
  int get hashCode => Object.hash(token, purpose, email);
}

/// `https://flight.heavenly.cl/app.html` — open the signed-in / guest home hub.
class AppHomeDeepLink extends ParsedDeepLink {
  const AppHomeDeepLink();

  @override
  bool operator ==(Object other) => other is AppHomeDeepLink;

  @override
  int get hashCode => runtimeType.hashCode;
}

class FlightDeepLink {
  static const productionHost = 'flight.heavenly.cl';
  static const androidPackage = 'cl.heavenly.flightvis';
  static const handoffTokenPrefix = 'h1.';

  static bool isClaimToken(String token) =>
      token.trim().startsWith(handoffTokenPrefix);

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

  static String? _claimQueryParam(Uri uri) {
    final raw = uri.queryParameters['claim'] ?? uri.queryParameters['claimToken'];
    if (raw == null) return null;
    final trimmed = raw.trim();
    return isClaimToken(trimmed) ? trimmed : null;
  }

  static ParsedDeepLink? parseHttpsUri(Uri uri) {
    if (!_isTrustedHost(uri)) return null;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length == 1 && segs[0] == 'app.html') {
      return const AppHomeDeepLink();
    }
    if (segs.length >= 4 && segs[0] == 'c' && segs[2] == 'q') {
      final slug = segs[1];
      final pathToken = Uri.decodeComponent(segs.sublist(3).join('/')).trim();
      final claimParam = _claimQueryParam(uri);
      final token = claimParam ?? pathToken;
      if (slug.isEmpty || token.isEmpty) return null;
      return CheckinDeepLink(clubSlug: slug, token: token);
    }
    if (segs.length == 2 && segs[0] == 'c') {
      final slug = segs[1];
      final claimParam = _claimQueryParam(uri);
      if (slug.isNotEmpty && claimParam != null) {
        return CheckinDeepLink(clubSlug: slug, token: claimParam);
      }
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
      final token = uri.queryParameters['token']?.trim();
      if (token != null && token.isNotEmpty) {
        return MagicLinkDeepLink(token: token);
      }
    }
    if (segs.length == 4 &&
        segs[0] == 'api' &&
        segs[1] == 'account' &&
        segs[2] == 'auth' &&
        segs[3] == 'magic') {
      final token = uri.queryParameters['token']?.trim();
      if (token != null && token.isNotEmpty) {
        final rawPurpose = uri.queryParameters['purpose']?.trim();
        final purpose =
            (rawPurpose != null && rawPurpose.isNotEmpty) ? rawPurpose : null;
        final email = _sanitizeEmail(uri.queryParameters['email']) ??
            extractEmailFromTokenClaims(token);
        return AccountMagicLinkDeepLink(
          token: token,
          purpose: purpose,
          email: email,
        );
      }
    }
    return null;
  }

  static String? _sanitizeEmail(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 254) return null;
    if (!trimmed.contains('@') || RegExp(r'[\s\r\n\t]').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  /// Extracts an `email` string claim from a base64url JWT payload if [token]
  /// is a JWT; returns `null` for opaque tokens or malformed payloads.
  static String? extractEmailFromTokenClaims(String token) {
    final parts = token.trim().split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(decoded);
      if (json is! Map<String, dynamic>) return null;
      final raw = json['email'];
      if (raw is! String) return null;
      return _sanitizeEmail(raw);
    } catch (_) {
      return null;
    }
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

    final query = intentUri.hasQuery ? '?${intentUri.query}' : '';
    try {
      return Uri.parse('$scheme://$host$path$query');
    } catch (_) {
      return null;
    }
  }

  static String? _intentParam(String fragment, String key) {
    final match = RegExp('$key=([^;]+)').firstMatch(fragment);
    return match?.group(1);
  }

  /// QR scan or paste: HTTPS check-in URL, `intent://`, or raw rotating/handoff token.
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