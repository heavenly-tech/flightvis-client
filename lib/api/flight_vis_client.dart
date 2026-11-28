import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app_config.dart';
import '../map/trail_styles.dart';
import 'flight_vis_api_paths.dart';

class FlightVisException implements Exception {
  FlightVisException(
    this.message, {
    this.statusCode,
    this.body,
    this.reason,
    this.serverMessage,
    this.retryAfterSeconds,
    this.retryAfterRaw,
  });

  final String message;
  final int? statusCode;
  final Map<String, dynamic>? body;

  /// Machine reason code from server (`body['reason']`, e.g. `used_claim`, `expired_qr`).
  final String? reason;

  /// Optional human-readable message returned by server (`body['message']`).
  final String? serverMessage;

  /// Optional parsed `Retry-After` delay in seconds (e.g. HTTP 429 responses).
  final int? retryAfterSeconds;

  /// Raw `Retry-After` HTTP header value (integer seconds or HTTP-date).
  final String? retryAfterRaw;

  /// PR #54: flight write/share management may return `404` instead of `403`
  /// when the resource is missing or not owned by the current pilot.
  bool get isFlightNotYoursOrMissing {
    if (statusCode != 403 && statusCode != 404) return false;
    final err = body?['error']?.toString().trim().toLowerCase();
    if (err == 'not found' || err == 'forbidden' || err == 'not yours') {
      return true;
    }
    if (statusCode == 404) return true;
    return false;
  }

  /// True when the server rejected the request with `403` because the club is
  /// suspended/unavailable (distinct from session expiry).
  bool get isClubUnavailable {
    if (statusCode != 403) return false;
    for (final raw in [body?['error'], reason, message]) {
      final norm = raw?.toString().trim().toLowerCase();
      if (norm == 'club unavailable' || norm == 'club_unavailable') {
        return true;
      }
    }
    return false;
  }

  /// True when the server rejected a batch as oversized (`413 Payload Too Large`
  /// or an explicit `"oversized"` / `"batch too large"` / `"payload too large"` error).
  bool get isOversizedBatch {
    if (statusCode == 413) return true;
    for (final raw in [body?['error'], reason, message]) {
      final norm = raw?.toString().trim().toLowerCase();
      if (norm == null || norm.isEmpty) continue;
      if (norm.contains('oversized') ||
          norm.contains('batch too large') ||
          norm.contains('payload too large')) {
        return true;
      }
    }
    return false;
  }

  /// Maximum honoured `Retry-After` delay (L-89: clamp to `[0, 1 hour]`).
  static const Duration maxRetryAfter = Duration(hours: 1);

  /// Parses a `Retry-After` HTTP header value (either integer seconds or an
  /// RFC 7231 / RFC 9110 HTTP-date) relative to [now] (defaults to UTC now),
  /// clamped to `[0, maxRetryAfter]` (past dates and negative values yield `0`).
  static Duration? parseRetryAfterDuration(String? raw, {DateTime? now}) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      if (seconds <= 0) return Duration.zero;
      if (seconds >= maxRetryAfter.inSeconds) return maxRetryAfter;
      return Duration(seconds: seconds);
    }
    if (RegExp(r'^[+-]?\d+$').hasMatch(trimmed)) {
      return trimmed.startsWith('-') ? Duration.zero : maxRetryAfter;
    }
    try {
      final target = HttpDate.parse(trimmed).toUtc();
      final reference = (now ?? DateTime.now()).toUtc();
      final diffMs = target.difference(reference).inMilliseconds;
      if (diffMs <= 0) return Duration.zero;
      if (diffMs >= maxRetryAfter.inMilliseconds) return maxRetryAfter;
      return Duration(milliseconds: diffMs);
    } catch (_) {
      return null;
    }
  }

  /// Parses an integer-seconds or HTTP-date `Retry-After` header into whole
  /// seconds (rounded up so the minimum wait is always respected), clamped to
  /// `[0, maxRetryAfter.inSeconds]`.
  static int? parseRetryAfterSeconds(String? raw, {DateTime? now}) {
    final d = parseRetryAfterDuration(raw, now: now);
    if (d == null) return null;
    if (d.inMilliseconds <= 0) return 0;
    final secs = (d.inMilliseconds + 999) ~/ 1000;
    return secs > maxRetryAfter.inSeconds ? maxRetryAfter.inSeconds : secs;
  }

  /// Resolves the `Retry-After` delay relative to an injectable [now] clock,
  /// clamped to `[0, maxRetryAfter]`.
  Duration? resolveRetryAfter({DateTime? now}) {
    if (retryAfterRaw != null) {
      final parsed = parseRetryAfterDuration(retryAfterRaw, now: now);
      if (parsed != null) return parsed;
    }
    if (retryAfterSeconds != null) {
      final s = retryAfterSeconds!;
      if (s <= 0) return Duration.zero;
      if (s >= maxRetryAfter.inSeconds) return maxRetryAfter;
      return Duration(seconds: s);
    }
    return null;
  }

  @override
  String toString() => message;
}

int? _parseTrailMinutes(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return null;
}

/// Pilot profile from login (no `licenseNo`), `/api/club/me` (includes `licenseNo`),
/// or synthesized for a club-less personal account (`isClublessAccount == true`).
class PilotProfile {
  PilotProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.status,
    required this.role,
    this.licenseNo,
    this.clubTrailMinutesDefault,
    this.emailVerified = false,
    this.isClublessAccount = false,
  });

  final String id;
  final String name;
  final String email;
  final String status;
  final String role;
  final String? licenseNo;
  final int? clubTrailMinutesDefault;

  /// Top-level `email_verified` boolean from `GET /api/club/me` or `GET /api/account/me`
  /// (false when missing or for guest sessions). Drives the public-visibility gate.
  final bool emailVerified;

  /// True when representing a signed-in global account with no active club
  /// membership ("Piloto público" mode).
  final bool isClublessAccount;

  factory PilotProfile.fromJson(
    Map<String, dynamic> json, {
    int? clubTrailMinutesDefault,
    bool? emailVerified,
  }) {
    final resolvedEmailVerified =
        emailVerified ?? (json['email_verified'] == true);
    return PilotProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      email: json['email'] as String,
      status: json['status'] as String,
      role: json['role'] as String,
      licenseNo: json['licenseNo'] as String?,
      clubTrailMinutesDefault: clubTrailMinutesDefault ??
          _parseTrailMinutes(json['clubTrailMinutesDefault']),
      emailVerified: resolvedEmailVerified,
      isClublessAccount: json['isClublessAccount'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'status': status,
        'role': role,
        if (licenseNo != null) 'licenseNo': licenseNo,
        if (clubTrailMinutesDefault != null)
          'clubTrailMinutesDefault': clubTrailMinutesDefault,
        'email_verified': emailVerified,
        if (isClublessAccount) 'isClublessAccount': true,
      };

  bool get isApproved => status == 'approved';
  bool get isGuest => status == 'guest';
}

/// Club membership entry from `/api/account/me`, `/api/account/login`, or
/// `/api/account/auth/magic/complete`.
class AccountMembership {
  const AccountMembership({
    required this.id,
    required this.clubId,
    required this.slug,
    required this.name,
    required this.role,
    required this.status,
  });

  final String id;
  final String clubId;
  final String slug;
  final String name;
  final String role;
  final String status;

  /// Matches server `club_memberships.status IN ('active', 'approved')`.
  bool get isActive => status == 'active' || status == 'approved';

  factory AccountMembership.fromJson(Map<String, dynamic> json) =>
      AccountMembership(
        id: json['id'] as String? ?? '',
        clubId: json['clubId'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        name: json['name'] as String? ?? (json['slug'] as String? ?? ''),
        role: json['role'] as String? ?? 'pilot',
        status: json['status'] as String? ?? 'pending',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'clubId': clubId,
        'slug': slug,
        'name': name,
        'role': role,
        'status': status,
      };
}

/// Global account profile from `GET /api/account/me`, `POST /api/account/login`,
/// or `POST /api/account/auth/magic/complete`.
class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.email,
    required this.emailVerified,
    this.emailVerifiedAt,
    this.activeMembershipId,
    this.memberships = const [],
  });

  final String id;
  final String email;
  final bool emailVerified;
  final int? emailVerifiedAt;
  final String? activeMembershipId;
  final List<AccountMembership> memberships;

  List<AccountMembership> get activeMemberships =>
      memberships.where((m) => m.isActive).toList(growable: false);

  bool get hasActiveClubMembership => activeMemberships.isNotEmpty;

  AccountMembership? get activeMembership {
    final targetId = activeMembershipId;
    if (targetId == null || targetId.isEmpty) return null;
    for (final m in memberships) {
      if (m.id == targetId) return m;
    }
    return null;
  }

  /// Synthesizes a [PilotProfile] for club-less (personal) mode so local
  /// buckets, UI headers, and email-verification gating work uniformly.
  PilotProfile toPersonalPilotProfile() {
    final displayName = email.contains('@') ? email.split('@').first : email;
    return PilotProfile(
      id: id,
      name: displayName.isNotEmpty ? displayName : email,
      email: email,
      status: 'approved',
      role: 'pilot',
      emailVerified: emailVerified,
      isClublessAccount: !hasActiveClubMembership,
    );
  }

  factory AccountProfile.fromJson(Map<String, dynamic> json) {
    final acct = json['account'] is Map<String, dynamic>
        ? json['account'] as Map<String, dynamic>
        : json;
    final verifiedAtRaw = acct['emailVerifiedAt'];
    final verifiedAt = verifiedAtRaw is num ? verifiedAtRaw.toInt() : null;
    // GET /api/account/me returns top-level `email_verified`;
    // POST /api/account/login and /api/account/auth/magic/complete return
    // nested `account.emailVerified`.
    final bool verified;
    if (json.containsKey('email_verified')) {
      verified = json['email_verified'] == true;
    } else if (acct.containsKey('emailVerified')) {
      verified = acct['emailVerified'] == true;
    } else {
      verified = verifiedAt != null;
    }
    final rawMemberships = json['memberships'] as List<dynamic>? ?? const [];
    final memberships = rawMemberships
        .whereType<Map<String, dynamic>>()
        .map(AccountMembership.fromJson)
        .toList(growable: false);
    final rawActiveId = (json['activeMembershipId'] as String?)?.trim();
    return AccountProfile(
      id: acct['id'] as String? ?? '',
      email: acct['email'] as String? ?? '',
      emailVerified: verified,
      emailVerifiedAt: verifiedAt,
      activeMembershipId:
          (rawActiveId != null && rawActiveId.isNotEmpty) ? rawActiveId : null,
      memberships: memberships,
    );
  }

  Map<String, dynamic> toJson() => {
        'account': {
          'id': id,
          'email': email,
          'emailVerifiedAt': emailVerifiedAt,
        },
        'email_verified': emailVerified,
        'activeMembershipId': activeMembershipId,
        'memberships': [for (final m in memberships) m.toJson()],
      };
}

/// Result of `POST /api/account/login` or `POST /api/account/auth/magic/complete`.
class AccountAuthResult {
  const AccountAuthResult({required this.profile, this.device});

  final AccountProfile profile;
  final DeviceRegistration? device;
}

/// Result of `POST /api/account/switch-club`.
class SwitchClubResult {
  const SwitchClubResult({
    required this.pilotId,
    required this.clubId,
    required this.activeMembershipId,
    required this.clubSlug,
    required this.clubName,
  });

  final String pilotId;
  final String clubId;
  final String activeMembershipId;
  final String clubSlug;
  final String clubName;

  factory SwitchClubResult.fromJson(Map<String, dynamic> json) {
    final club = json['club'] is Map<String, dynamic>
        ? json['club'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return SwitchClubResult(
      pilotId: json['pilotId'] as String? ?? '',
      clubId: json['clubId'] as String? ?? (club['id'] as String? ?? ''),
      activeMembershipId: json['activeMembershipId'] as String? ?? '',
      clubSlug: club['slug'] as String? ?? '',
      clubName: club['name'] as String? ?? (club['slug'] as String? ?? ''),
    );
  }
}

/// Result of `POST /api/ingest`.
class IngestBatchResult {
  const IngestBatchResult({required this.ok, required this.accepted});

  final bool ok;
  final int accepted;

  factory IngestBatchResult.fromJson(Map<String, dynamic> json) =>
      IngestBatchResult(
        ok: json['ok'] == true,
        accepted: (json['accepted'] as num?)?.toInt() ?? 0,
      );
}

class TailOption {
  TailOption({required this.id, required this.tail, required this.typeCode});

  final String id;
  final String tail;
  /// Server field `type_code` (snake_case) per PR #15.
  final String typeCode;

  factory TailOption.fromJson(Map<String, dynamic> json) => TailOption(
        id: json['id'] as String,
        tail: json['tail'] as String,
        typeCode: json['type_code'] as String,
      );
}

class ClubSummary {
  ClubSummary({required this.slug, required this.name});

  final String slug;
  final String name;

  factory ClubSummary.fromJson(Map<String, dynamic> json) {
    final club = json['club'];
    if (club is Map<String, dynamic>) {
      return ClubSummary(
        slug: club['slug'] as String? ?? '',
        name: club['name'] as String? ?? club['slug'] as String? ?? '',
      );
    }
    return ClubSummary(
      slug: json['slug'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['slug'] as String? ?? '',
    );
  }
}

class CheckinResult {
  CheckinResult({
    required this.ok,
    this.id,
    this.expiresAtUtc,
    this.clubSlug,
    this.clubName,
    this.status,
    this.needsSignup = false,
    this.deviceId,
    this.deviceToken,
    this.pilotId,
    this.clubId,
  });

  final bool ok;
  final String? id;
  final DateTime? expiresAtUtc;
  final String? clubSlug;
  final String? clubName;

  /// Pilot status from server (`guest`, `approved`, `pending`, …).
  final String? status;

  /// Whether the server indicates the guest still needs to claim/create an account.
  final bool needsSignup;

  /// Raw device id minted by server on bearerless/multi-club check-in (never sent as OsmAnd `id=`).
  final String? deviceId;

  /// Device token minted or rotated by server (`json['token']`), used as Bearer and OsmAnd `id=`.
  final String? deviceToken;

  /// Target pilot row id returned by E1 multi-club check-in (`json['pilotId']`).
  final String? pilotId;

  /// Target club id returned by E1 multi-club check-in (`json['clubId']`).
  final String? clubId;

  bool get isGuest => status == 'guest' || needsSignup;

  factory CheckinResult.fromJson(Map<String, dynamic> json) {
    final raw = json['expiresAt'] as String?;
    DateTime? expires;
    if (raw != null && raw.isNotEmpty) {
      expires = DateTime.parse(raw).toUtc();
    }
    String? slug;
    String? name;
    final club = json['club'];
    if (club is Map<String, dynamic>) {
      slug = club['slug'] as String?;
      name = club['name'] as String?;
    }
    slug ??= json['clubSlug'] as String?;
    name ??= json['clubName'] as String?;
    final rawToken = (json['token'] as String?)?.trim();
    final rawDeviceId = (json['deviceId'] as String?)?.trim();
    final rawPilotId = (json['pilotId'] as String?)?.trim();
    final rawClubId = (json['clubId'] as String?)?.trim();
    return CheckinResult(
      ok: json['ok'] == true,
      id: json['id'] as String?,
      expiresAtUtc: expires,
      clubSlug: slug,
      clubName: name,
      status: json['status'] as String?,
      needsSignup: json['needsSignup'] == true,
      deviceId: (rawDeviceId != null && rawDeviceId.isNotEmpty) ? rawDeviceId : null,
      deviceToken: (rawToken != null && rawToken.isNotEmpty) ? rawToken : null,
      pilotId: (rawPilotId != null && rawPilotId.isNotEmpty) ? rawPilotId : null,
      clubId: (rawClubId != null && rawClubId.isNotEmpty) ? rawClubId : null,
    );
  }

  int? expiresAtEpochMs({int? nowMs}) {
    if (expiresAtUtc != null) {
      return expiresAtUtc!.millisecondsSinceEpoch;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return now + AppConfig.defaultCheckinValidMinutes * 60 * 1000;
  }
}

class DeviceRegistration {
  DeviceRegistration({required this.id, required this.token, this.label});

  final String id;
  final String token;
  final String? label;

  factory DeviceRegistration.fromJson(Map<String, dynamic> json) {
    final token = (json['token'] as String?)?.trim();
    if (token == null || token.isEmpty) {
      throw FlightVisException('device token missing in response');
    }
    return DeviceRegistration(
      id: json['id'] as String? ?? '',
      token: token,
      label: json['label'] as String?,
    );
  }
}

int? _parseEpochMs(dynamic raw) {
  if (raw is int) return raw > 0 ? raw : null;
  if (raw is num && raw.isFinite) {
    final v = raw.toInt();
    return v > 0 ? v : null;
  }
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final asInt = int.tryParse(trimmed);
    if (asInt != null) return asInt > 0 ? asInt : null;
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) return parsed.toUtc().millisecondsSinceEpoch;
  }
  return null;
}

class MyFlightSummary {
  MyFlightSummary({
    required this.id,
    required this.tail,
    required this.status,
    this.startedAtMs,
  });

  final String id;
  final String tail;
  final String status;
  final int? startedAtMs;

  bool get isActive => status == 'active';

  factory MyFlightSummary.fromJson(Map<String, dynamic> json) => MyFlightSummary(
        id: json['id'] as String,
        tail: json['tail'] as String? ?? '',
        status: json['status'] as String? ?? '',
        startedAtMs: _parseEpochMs(
          json['startedAt'] ?? json['started_at'] ?? json['startedAtMs'],
        ),
      );
}

class StartFlightResult {
  StartFlightResult({
    required this.id,
    required this.visibility,
    required this.showPilotNamePublic,
    this.trailMinutes,
    this.hasTrailMinutes = false,
    this.startedAtMs,
  });

  final String id;
  final String visibility;
  final bool showPilotNamePublic;
  final int? trailMinutes;
  final bool hasTrailMinutes;
  final int? startedAtMs;

  factory StartFlightResult.fromJson(Map<String, dynamic> json) =>
      StartFlightResult(
        id: json['id'] as String,
        visibility: json['visibility'] as String,
        showPilotNamePublic: json['showPilotNamePublic'] as bool? ?? false,
        trailMinutes: _parseTrailMinutes(json['trailMinutes']),
        hasTrailMinutes: json.containsKey('trailMinutes'),
        startedAtMs: _parseEpochMs(
          json['startedAt'] ?? json['started_at'] ?? json['startedAtMs'],
        ),
      );
}

/// Single point `[t_ms, lat, lon, alt|null]` returned by `GET /api/me/live-trails`.
class LiveTrailPoint {
  const LiveTrailPoint({
    required this.timeMs,
    required this.latitude,
    required this.longitude,
    this.altitude,
  });

  final int timeMs;
  final double latitude;
  final double longitude;
  final double? altitude;

  static LiveTrailPoint? fromJsonList(dynamic raw) {
    if (raw is! List || raw.length < 3) return null;
    final t = raw[0];
    final lat = raw[1];
    final lon = raw[2];
    if (t is! num || lat is! num || lon is! num) return null;
    final latD = lat.toDouble();
    final lonD = lon.toDouble();
    if (!latD.isFinite || !lonD.isFinite || latD < -90 || latD > 90 || lonD < -180 || lonD > 180) {
      return null;
    }
    final altRaw = raw.length >= 4 ? raw[3] : null;
    final altD = altRaw is num && altRaw.toDouble().isFinite ? altRaw.toDouble() : null;
    return LiveTrailPoint(
      timeMs: t.toInt(),
      latitude: latD,
      longitude: lonD,
      altitude: altD,
    );
  }
}

/// Another aircraft's live trail returned by `GET /api/me/live-trails` or
/// `GET /api/public/live-trails`.
class LiveTrailFlight {
  const LiveTrailFlight({
    required this.flightId,
    required this.tail,
    required this.layer,
    required this.trailMinutes,
    required this.points,
    this.tailSource = 'club',
    this.otherClub = false,
    this.nonClub = false,
  });

  final String flightId;
  final String tail;
  final String layer;
  final int trailMinutes;
  final List<LiveTrailPoint> points;

  /// `'club'` (club-managed tail) or `'pilot'` (pilot-entered free-text tail).
  final String tailSource;

  /// PR #54 L-92: `true` for nearby public flights belonging to another club.
  final bool otherClub;

  /// PR #54 L-92: `true` for nearby club-less / pilot-tail flights.
  final bool nonClub;

  bool get isPublic => layer == 'public';
  bool get isClub => layer == 'club';
  bool get isDistinctNonOwnClub => isPublic || otherClub || nonClub;
  LiveTrailPoint? get latestPoint => points.isEmpty ? null : points.last;

  factory LiveTrailFlight.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>? ?? const [];
    final parsedPoints = <LiveTrailPoint>[];
    for (final entry in rawPoints) {
      final point = LiveTrailPoint.fromJsonList(entry);
      if (point != null) parsedPoints.add(point);
    }
    final rawTailSource = (json['tailSource'] as String?)?.trim();
    return LiveTrailFlight(
      flightId: json['flightId'] as String? ?? '',
      tail: json['tail'] as String? ?? '',
      layer: json['layer'] as String? ?? 'club',
      trailMinutes: _parseTrailMinutes(json['trailMinutes']) ?? 0,
      points: List<LiveTrailPoint>.unmodifiable(parsedPoints),
      tailSource: rawTailSource == 'pilot' ? 'pilot' : 'club',
      otherClub: json['otherClub'] == true,
      nonClub: json['nonClub'] == true,
    );
  }
}

/// Server-enforced bounds reported by `GET /api/me/live-trails`.
class LiveTrailsCaps {
  const LiveTrailsCaps({
    required this.maxFlights,
    required this.maxPointsPerFlight,
    required this.maxWindowMinutes,
  });

  final int maxFlights;
  final int maxPointsPerFlight;
  final int maxWindowMinutes;

  factory LiveTrailsCaps.fromJson(Map<String, dynamic> json) => LiveTrailsCaps(
        maxFlights: (json['maxFlights'] as num?)?.toInt() ?? 50,
        maxPointsPerFlight: (json['maxPointsPerFlight'] as num?)?.toInt() ?? 300,
        maxWindowMinutes: (json['maxWindowMinutes'] as num?)?.toInt() ?? 120,
      );
}

/// Parsed response from `GET /api/me/live-trails` (supports `200` and `304`).
class LiveTrailsResponse {
  const LiveTrailsResponse({
    required this.flights,
    this.caps,
    this.etag,
    this.notModified = false,
  });

  const LiveTrailsResponse.notModified({this.etag})
      : flights = const [],
        caps = null,
        notModified = true;

  final List<LiveTrailFlight> flights;
  final LiveTrailsCaps? caps;
  final String? etag;
  final bool notModified;
}

/// Typed HTTP client for heavenly-tech/flight_vis club & account APIs (PR #15 + E1).
class FlightVisClient {
  FlightVisClient({
    required this.baseUrl,
    http.Client? httpClient,
    String? sessionId,
    String? accountSessionId,
    String? deviceToken,
    String? personalDeviceToken,
    String? clubSlug,
  })  : _http = httpClient ?? http.Client(),
        _sessionId = sessionId,
        _accountSessionId = accountSessionId,
        _deviceToken = deviceToken,
        _personalDeviceToken = personalDeviceToken,
        _clubSlug = clubSlug;

  static const passkeyRpId = 'flight.heavenly.cl';

  String baseUrl;
  final http.Client _http;
  String? _sessionId;
  String? _accountSessionId;
  String? _signupNonce;
  String? _deviceToken;
  String? _personalDeviceToken;
  String? _clubSlug;
  String? _acceptLanguage;
  int? _clubTrailMinutesDefault;

  String? get sessionId => _sessionId;
  String? get accountSessionId => _accountSessionId;
  String? get deviceToken => _deviceToken;
  String? get personalDeviceToken => _personalDeviceToken;
  int? get clubTrailMinutesDefault => _clubTrailMinutesDefault;
  bool get hasSession => _sessionId != null && _sessionId!.isNotEmpty;
  bool get hasAccountSession =>
      _accountSessionId != null && _accountSessionId!.isNotEmpty;
  bool get hasAnySession => hasSession || hasAccountSession;
  bool get hasDeviceToken => _deviceToken != null && _deviceToken!.isNotEmpty;
  bool get hasPersonalDeviceToken =>
      _personalDeviceToken != null && _personalDeviceToken!.isNotEmpty;

  void setSessionId(String? value) => _sessionId = value;
  void setAccountSessionId(String? value) => _accountSessionId = value;
  void setDeviceToken(String? value) => _deviceToken = value;
  void setPersonalDeviceToken(String? value) => _personalDeviceToken = value;
  void setClubTrailMinutesDefault(int? value) => _clubTrailMinutesDefault = value;

  String? deviceTokenForFlightMode(String flightMode) =>
      flightMode == 'personal' ? _personalDeviceToken : _deviceToken;

  void setAcceptLanguage(String? tag) {
    if (tag == null || tag.trim().isEmpty) {
      _acceptLanguage = null;
    } else {
      _acceptLanguage = tag.trim();
    }
  }

  void setClubSlug(String? value) {
    if (value == null || value.trim().isEmpty) {
      _clubSlug = null;
    } else {
      _clubSlug = value.trim();
    }
  }

  String? get clubSlug => _clubSlug;
  String? get acceptLanguage => _acceptLanguage;

  Uri _uri(String path) => Uri.parse('${AppConfig.normalizeBaseUrl(baseUrl)}$path');

  Map<String, String> _headers({
    bool jsonBody = false,
    bool acceptJson = false,
    String? bearerOverride,
    bool omitBearer = false,
    bool includeSignupNonce = false,
  }) {
    final headers = <String, String>{
      if (jsonBody) 'Content-Type': 'application/json',
      if (acceptJson) 'Accept': 'application/json',
    };
    final cookies = <String>[];
    if (_accountSessionId != null && _accountSessionId!.isNotEmpty) {
      cookies.add('fv_account_session=$_accountSessionId');
    }
    if (_sessionId != null && _sessionId!.isNotEmpty) {
      cookies.add('fv_club_session=$_sessionId');
    }
    if (includeSignupNonce &&
        _signupNonce != null &&
        _signupNonce!.isNotEmpty) {
      cookies.add('__Host-fv_account_signup_nonce=$_signupNonce');
    }
    if (cookies.isNotEmpty) {
      headers['Cookie'] = cookies.join('; ');
    }
    if (!omitBearer) {
      final bearer = bearerOverride ?? _deviceToken;
      if (bearer != null && bearer.isNotEmpty) {
        headers['Authorization'] = 'Bearer $bearer';
      }
    }
    if (_acceptLanguage != null && _acceptLanguage!.isNotEmpty) {
      headers['Accept-Language'] = _acceptLanguage!;
    }
    return headers;
  }

  String? _cookieFromResponse(http.Response response, String cookieName) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return null;
    final pattern = RegExp(
      '(?:^|[,;]\\s*)${RegExp.escape(cookieName)}=([^;,\\r\\n]*)',
    );
    String? found;
    for (final m in pattern.allMatches(raw)) {
      final value = m.group(1)?.trim();
      if (value != null && value.isNotEmpty) {
        found = value;
      }
    }
    return found;
  }

  String? _sessionFromResponse(http.Response response) =>
      _cookieFromResponse(response, 'fv_club_session');

  String? _accountSessionFromResponse(http.Response response) =>
      _cookieFromResponse(response, 'fv_account_session');

  Map<String, dynamic> _decodeJson(http.Response response) {
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void _throwForError(http.Response response) {
    Map<String, dynamic>? body;
    try {
      body = _decodeJson(response);
    } catch (_) {}
    final rawReason = body?['reason']?.toString().trim();
    final reason = (rawReason != null && rawReason.isNotEmpty) ? rawReason : null;
    final rawServerMessage = body?['message']?.toString().trim();
    final serverMessage =
        (rawServerMessage != null && rawServerMessage.isNotEmpty) ? rawServerMessage : null;
    final error = body?['error']?.toString() ?? reason ?? 'HTTP ${response.statusCode}';
    final retryAfterRaw = response.headers['retry-after'];
    throw FlightVisException(
      error,
      statusCode: response.statusCode,
      body: body,
      reason: reason,
      serverMessage: serverMessage,
      retryAfterSeconds: FlightVisException.parseRetryAfterSeconds(retryAfterRaw),
      retryAfterRaw: retryAfterRaw,
    );
  }

  /// Login then enrich profile from `GET /api/club/me` (`licenseNo`).
  Future<PilotProfile> login(
    String email,
    String password, {
    String? installId,
  }) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.clubLogin),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        if (installId != null && installId.isNotEmpty) 'installId': installId,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final session = _sessionFromResponse(response);
    if (session != null) _sessionId = session;
    final loginPilot = PilotProfile.fromJson(
      body['pilot'] as Map<String, dynamic>,
      emailVerified: body['email_verified'] == true,
    );
    try {
      final me = await meProfile();
      return me ?? loginPilot;
    } on FlightVisException {
      return loginPilot;
    }
  }

  Future<PilotProfile?> meProfile() async {
    if (!hasAnySession) return null;
    final response = await _http.get(_uri(FlightVisApiPaths.clubMe), headers: _headers());
    if (response.statusCode == 401 || response.statusCode == 403) {
      _clubTrailMinutesDefault = null;
      _throwForError(response);
    }
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final topDefault = _parseTrailMinutes(body['clubTrailMinutesDefault']);
    final pilot = body['pilot'];
    if (pilot == null) {
      _clubTrailMinutesDefault = topDefault;
      return null;
    }
    final pilotMap = pilot as Map<String, dynamic>;
    final clubDefault =
        topDefault ?? _parseTrailMinutes(pilotMap['clubTrailMinutesDefault']);
    _clubTrailMinutesDefault = clubDefault;
    final topEmailVerified = body['email_verified'] == true;
    return PilotProfile.fromJson(
      pilotMap,
      clubTrailMinutesDefault: clubDefault,
      emailVerified: topEmailVerified,
    );
  }

  /// Global account profile (`GET /api/account/me`, `account_routes.rs:538`).
  Future<AccountProfile?> accountMe() async {
    if (!hasAccountSession) return null;
    final response = await _http.get(
      _uri(FlightVisApiPaths.accountMe),
      headers: _headers(acceptJson: true),
    );
    if (response.statusCode != 200) _throwForError(response);
    return AccountProfile.fromJson(_decodeJson(response));
  }

  /// Creates a global account (`POST /api/account/signup`, `account_routes.rs:37`).
  /// Omit [clubSlug] for a club-less ("Piloto público") account.
  Future<void> accountSignup({
    required String email,
    String? password,
    String? clubSlug,
  }) async {
    final trimmedSlug = clubSlug?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountSignup),
      headers: _headers(jsonBody: true, acceptJson: true),
      body: jsonEncode({
        'email': email.trim(),
        if (password != null && password.isNotEmpty) 'password': password,
        if (trimmedSlug != null && trimmedSlug.isNotEmpty)
          'clubSlug': trimmedSlug,
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      _throwForError(response);
    }
    final nonce =
        _cookieFromResponse(response, '__Host-fv_account_signup_nonce');
    if (nonce != null) _signupNonce = nonce;
  }

  /// Sends a global account magic link (`POST /api/account/magic-link`, `account_routes.rs:386`).
  Future<void> sendAccountMagicLink(String email, {String? locale}) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountMagicLink),
      headers: _headers(jsonBody: true, acceptJson: true),
      body: jsonEncode({
        'email': email.trim(),
        if (locale != null && locale.isNotEmpty) 'locale': locale,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
  }

  /// Email + password login for a global account (`POST /api/account/login`, `account_routes.rs:414`).
  /// When [installId] is provided, the server lazily ensures the personal pilot
  /// and returns a personal device token in `body['device']`.
  Future<AccountAuthResult> accountLogin(
    String email,
    String password, {
    String? installId,
    String? label,
    String? model,
  }) async {
    final trimmedInstallId = installId?.trim();
    final trimmedLabel = label?.trim();
    final trimmedModel = model?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountLogin),
      headers: _headers(jsonBody: true, acceptJson: true, omitBearer: true),
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        if (trimmedInstallId != null && trimmedInstallId.isNotEmpty)
          'installId': trimmedInstallId,
        if (trimmedLabel != null && trimmedLabel.isNotEmpty)
          'label': trimmedLabel,
        if (trimmedModel != null && trimmedModel.isNotEmpty)
          'model': trimmedModel,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return _parseAccountAuthResponse(response);
  }

  /// Completes an `/api/account/auth/magic` App Link (`POST /api/account/auth/magic/complete`,
  /// `account_routes.rs:1102`).
  Future<AccountAuthResult> completeAccountMagicLink(
    String token, {
    String? purpose,
    String? installId,
    String? label,
    String? model,
  }) async {
    final trimmedPurpose = purpose?.trim();
    final trimmedInstallId = installId?.trim();
    final trimmedLabel = label?.trim();
    final trimmedModel = model?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountAuthMagicComplete),
      headers: _headers(
        jsonBody: true,
        acceptJson: true,
        omitBearer: true,
        includeSignupNonce: true,
      ),
      body: jsonEncode({
        'token': token.trim(),
        if (trimmedPurpose != null && trimmedPurpose.isNotEmpty)
          'purpose': trimmedPurpose,
        if (trimmedInstallId != null && trimmedInstallId.isNotEmpty)
          'installId': trimmedInstallId,
        if (trimmedLabel != null && trimmedLabel.isNotEmpty)
          'label': trimmedLabel,
        if (trimmedModel != null && trimmedModel.isNotEmpty)
          'model': trimmedModel,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    _signupNonce = null;
    return _parseAccountAuthResponse(response);
  }

  AccountAuthResult _parseAccountAuthResponse(http.Response response) {
    final accountSession = _accountSessionFromResponse(response);
    if (accountSession != null) _accountSessionId = accountSession;
    final clubSession = _sessionFromResponse(response);
    if (clubSession != null) _sessionId = clubSession;
    final body = _decodeJson(response);
    final profile = AccountProfile.fromJson(body);
    DeviceRegistration? device;
    final rawDevice = body['device'];
    if (rawDevice is Map<String, dynamic>) {
      try {
        device = DeviceRegistration.fromJson(rawDevice);
        if (profile.activeMembershipId == null) {
          _personalDeviceToken = device.token;
        } else {
          _deviceToken = device.token;
        }
      } catch (_) {}
    }
    return AccountAuthResult(profile: profile, device: device);
  }

  /// Mints or rotates a device token for the account (`POST /api/account/devices`,
  /// `club/routes.rs:3366`). Use `mode: 'personal'` for club-less flights.
  Future<DeviceRegistration> registerAccountDevice({
    required String mode,
    required String installId,
    String label = 'Android',
    String? model,
  }) async {
    final trimmedModel = model?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountDevices),
      headers: _headers(jsonBody: true, acceptJson: true),
      body: jsonEncode({
        'mode': mode,
        'label': label,
        'installId': installId,
        if (trimmedModel != null && trimmedModel.isNotEmpty)
          'model': trimmedModel,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    final reg = DeviceRegistration.fromJson(_decodeJson(response));
    if (mode == 'personal') {
      _personalDeviceToken = reg.token;
    } else if (mode == 'club') {
      _deviceToken = reg.token;
    }
    return reg;
  }

  /// Switches the active club membership for a multi-club account
  /// (`POST /api/account/switch-club`, `account_routes.rs:589`).
  Future<SwitchClubResult> switchClub(String membershipId) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.accountSwitchClub),
      headers: _headers(jsonBody: true, acceptJson: true),
      body: jsonEncode({'membershipId': membershipId.trim()}),
    );
    if (response.statusCode != 200) _throwForError(response);
    final clubSession = _sessionFromResponse(response);
    if (clubSession != null) _sessionId = clubSession;
    final result = SwitchClubResult.fromJson(_decodeJson(response));
    if (result.clubSlug.isNotEmpty) {
      _clubSlug = result.clubSlug;
    }
    return result;
  }

  Future<void> logout({String? installId}) async {
    if (!hasAnySession) {
      _sessionId = null;
      _accountSessionId = null;
      _personalDeviceToken = null;
      _clubTrailMinutesDefault = null;
      return;
    }
    final useAccountLogout = hasAccountSession;
    final response = await _http.post(
      _uri(
        useAccountLogout
            ? FlightVisApiPaths.accountLogout
            : FlightVisApiPaths.clubLogout,
      ),
      headers: _headers(jsonBody: !useAccountLogout && installId != null),
      body: (!useAccountLogout && installId != null)
          ? jsonEncode({'installId': installId})
          : null,
    );
    if (response.statusCode != 200) _throwForError(response);
    _sessionId = null;
    _accountSessionId = null;
    _personalDeviceToken = null;
    _clubTrailMinutesDefault = null;
  }

  Future<ClubSummary> fetchClub(String slug) async {
    final response = await _http.get(
      _uri(FlightVisApiPaths.clubBySlug(slug)),
      headers: _headers(),
    );
    if (response.statusCode == 404) {
      return ClubSummary(slug: slug, name: slug);
    }
    if (response.statusCode != 200) _throwForError(response);
    return ClubSummary.fromJson(_decodeJson(response));
  }

  Future<void> sendMagicLink(String email, {String? locale}) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.authMagicSend),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'email': email.trim(),
        if (locale != null && locale.isNotEmpty) 'locale': locale,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
  }

  Future<PilotProfile> completeMagicLink(String token, {String? clubSlug}) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.authMagicComplete),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'token': token.trim(),
        if (clubSlug != null && clubSlug.isNotEmpty) 'slug': clubSlug,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    final session = _sessionFromResponse(response);
    if (session != null) _sessionId = session;
    final body = _decodeJson(response);
    final pilot = body['pilot'];
    if (pilot is Map<String, dynamic>) {
      return PilotProfile.fromJson(
        pilot,
        emailVerified: body['email_verified'] == true,
      );
    }
    final me = await meProfile();
    if (me != null) return me;
    throw FlightVisException('magic link login failed');
  }

  Future<Map<String, dynamic>> passkeyLoginBegin(String email) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.passkeyLoginOptions),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'email': email.trim()}),
    );
    if (response.statusCode != 200) _throwForError(response);
    return _decodeJson(response);
  }

  Future<PilotProfile> passkeyLoginFinish({
    required String nonce,
    required Map<String, dynamic> credential,
  }) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.passkeyLoginVerify),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'nonce': nonce, 'credential': credential}),
    );
    if (response.statusCode != 200) _throwForError(response);
    final session = _sessionFromResponse(response);
    if (session != null) _sessionId = session;
    final body = _decodeJson(response);
    final pilot = body['pilot'];
    if (pilot is Map<String, dynamic>) {
      return PilotProfile.fromJson(
        pilot,
        emailVerified: body['email_verified'] == true,
      );
    }
    final me = await meProfile();
    if (me == null) {
      throw FlightVisException('passkey login failed');
    }
    return me;
  }

  Future<CheckinResult> checkin(
    String kioskToken, {
    String? clubSlug,
    String? deviceId,
    String? installId,
    String? label,
    String? model,
  }) async {
    if (clubSlug != null && clubSlug.isNotEmpty) {
      _clubSlug = clubSlug;
    }
    final trimmedDeviceId = deviceId?.trim();
    final trimmedInstallId = installId?.trim();
    final trimmedLabel = label?.trim();
    final trimmedModel = model?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.checkin),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'token': kioskToken.trim(),
        if (trimmedDeviceId != null && trimmedDeviceId.isNotEmpty)
          'deviceId': trimmedDeviceId,
        if (trimmedInstallId != null && trimmedInstallId.isNotEmpty)
          'installId': trimmedInstallId,
        if (trimmedLabel != null && trimmedLabel.isNotEmpty)
          'label': trimmedLabel,
        if (trimmedModel != null && trimmedModel.isNotEmpty)
          'model': trimmedModel,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    final result = CheckinResult.fromJson(_decodeJson(response));
    if (!result.ok) {
      throw FlightVisException('check-in failed');
    }
    if (result.deviceToken != null && result.deviceToken!.isNotEmpty) {
      _deviceToken = result.deviceToken;
    }
    _clubSlug = result.clubSlug ?? clubSlug ?? _clubSlug;
    return result;
  }

  Future<List<TailOption>> tails() async {
    final response = await _http.get(_uri(FlightVisApiPaths.meTails), headers: _headers());
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final list = (body['tails'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(TailOption.fromJson)
        .toList();
    return list;
  }

  Future<StartFlightResult> startFlight({
    required String tail,
    String visibility = 'club',
    bool showPilotNamePublic = false,
    int? trailMinutes,
    bool sendTrail = true,
    String? mode,
    String? deviceToken,
  }) async {
    final effectiveBearer =
        deviceToken ?? (mode == 'personal' ? _personalDeviceToken : null);
    final response = await _http.post(
      _uri(FlightVisApiPaths.flights),
      headers: _headers(jsonBody: true, bearerOverride: effectiveBearer),
      body: jsonEncode({
        if (mode != null && mode.isNotEmpty) 'mode': mode,
        'tail': tail,
        'visibility': visibility,
        'show_pilot_name_public': showPilotNamePublic,
        if (sendTrail && trailMinutes != null) 'trailMinutes': trailMinutes,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return StartFlightResult.fromJson(_decodeJson(response));
  }

  /// Uploads a batch of queued fixes (`POST /api/ingest`, `live/ingest.rs:39`,
  /// `live/types.rs:43-61`) using the device bearer token.
  Future<IngestBatchResult> ingestBatch(
    List<Map<String, dynamic>> fixes, {
    String? deviceToken,
  }) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.ingest),
      headers: _headers(
        jsonBody: true,
        acceptJson: true,
        bearerOverride: deviceToken,
      ),
      body: jsonEncode({'fixes': fixes}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _throwForError(response);
    }
    return IngestBatchResult.fromJson(_decodeJson(response));
  }

  /// Guest pilot session (`POST /api/devices/anonymous` → server `post_guest`).
  Future<PilotProfile> startGuestSession({String name = 'Android'}) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.devicesAnonymous),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode != 200) _throwForError(response);
    final session = _sessionFromResponse(response);
    if (session != null) _sessionId = session;
    final body = _decodeJson(response);
    final pilot = body['pilot'];
    if (pilot is Map<String, dynamic>) {
      return PilotProfile.fromJson(pilot);
    }
    throw FlightVisException('guest session failed');
  }

  /// Logged-in or guest-session pilot device (`POST /api/me/devices`).
  ///
  /// Skips the network call and returns `null` when there is no active session.
  /// Also returns `null` when the server replies with `401` or a no-session
  /// no-op (`{"ok": true, "ignored": true}`).
  Future<DeviceRegistration?> registerDevice({
    String label = 'Android',
    required String installId,
    String? model,
  }) async {
    if (!hasSession) return null;
    final response = await _http.post(
      _uri(FlightVisApiPaths.meDevices),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'label': label,
        'installId': installId,
        if (model != null && model.isNotEmpty) 'model': model,
      }),
    );
    if (response.statusCode == 401) return null;
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    if (body['ignored'] == true) return null;
    return DeviceRegistration.fromJson(body);
  }

  Future<List<MyFlightSummary>> myFlights({
    String? mode,
    String? deviceToken,
  }) async {
    final effectiveBearer =
        deviceToken ?? (mode == 'personal' ? _personalDeviceToken : null);
    if (!hasAnySession && (effectiveBearer == null || effectiveBearer.isEmpty)) {
      return const [];
    }
    final baseUri = _uri(FlightVisApiPaths.meFlights);
    final uri = (mode != null && mode.isNotEmpty)
        ? baseUri.replace(queryParameters: {'mode': mode})
        : baseUri;
    final response = await _http.get(
      uri,
      headers: _headers(bearerOverride: effectiveBearer),
    );
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    return (body['flights'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(MyFlightSummary.fromJson)
        .toList();
  }

  /// Returns true if [flightId] is still `active` on the server (session or bearer required).
  Future<bool> isFlightActiveOnServer(
    String flightId, {
    String? mode,
    String? deviceToken,
  }) async {
    final flights = await myFlights(mode: mode, deviceToken: deviceToken);
    return flights.any((f) => f.id == flightId && f.isActive);
  }

  /// Polls other aircraft trails (`GET /api/me/live-trails?layers=...`).
  ///
  /// When both [includeClub] and [includePublic] are `false`, makes NO network
  /// call and returns an empty response. When [includePublic] is `true`, finite
  /// [lat] and [lon] coordinates are required: if missing or invalid, `public`
  /// is omitted from `layers` (sending club-only when [includeClub] is `true`,
  /// or skipping the network call otherwise). When [includePublic] is `false`,
  /// `lat`, `lon`, and `radius_km` are never sent. Supports weak ETag caching
  /// via [ifNoneMatch] (`304 Not Modified`).
  Future<LiveTrailsResponse> fetchLiveTrails({
    required bool includeClub,
    required bool includePublic,
    double? lat,
    double? lon,
    int? radiusKm,
    String? ifNoneMatch,
  }) async {
    final hasValidCoords = _hasValidCoordinates(lat, lon);
    final effectiveIncludePublic = includePublic && hasValidCoords;
    final layers = buildLiveTrailsLayersParam(
      includeClub: includeClub,
      includePublic: effectiveIncludePublic,
    );
    if (layers == null) {
      return const LiveTrailsResponse(flights: []);
    }
    final queryParameters = <String, String>{
      'layers': layers,
      if (effectiveIncludePublic) ...{
        'lat': _formatCoordinate(lat!),
        'lon': _formatCoordinate(lon!),
        if (radiusKm != null) 'radius_km': radiusKm.toString(),
      },
    };
    final uri = _uri(FlightVisApiPaths.meLiveTrails).replace(
      queryParameters: queryParameters,
    );
    final headers = _headers();
    if (ifNoneMatch != null && ifNoneMatch.isNotEmpty) {
      headers['If-None-Match'] = ifNoneMatch;
    }
    final response = await _http.get(uri, headers: headers);
    final responseEtag = response.headers['etag'];
    if (response.statusCode == 304) {
      return LiveTrailsResponse.notModified(etag: responseEtag ?? ifNoneMatch);
    }
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final rawFlights = body['flights'] as List<dynamic>? ?? const [];
    final flights = rawFlights
        .whereType<Map<String, dynamic>>()
        .map(LiveTrailFlight.fromJson)
        .toList(growable: false);
    final rawCaps = body['caps'];
    final caps = rawCaps is Map<String, dynamic>
        ? LiveTrailsCaps.fromJson(rawCaps)
        : null;
    return LiveTrailsResponse(
      flights: flights,
      caps: caps,
      etag: responseEtag,
    );
  }

  /// Polls nearby public aircraft trails anonymously via
  /// `GET /api/public/live-trails?lat=...&lon=...&radius_km=...[&min_agl_ft=...]`.
  ///
  /// Never sends `Cookie` or `Authorization` headers (only `Accept-Language`
  /// and optional `If-None-Match`). Skips the network call when coordinates are
  /// invalid. When [minAglFt] is non-null, clamps it to `0..20000` and sends
  /// `min_agl_ft`.
  Future<LiveTrailsResponse> fetchPublicLiveTrails({
    required double lat,
    required double lon,
    required int radiusKm,
    int? minAglFt,
    String? ifNoneMatch,
  }) async {
    if (!_hasValidCoordinates(lat, lon)) {
      return const LiveTrailsResponse(flights: []);
    }
    final clampedRadius = radiusKm.clamp(5, 500);
    final clampedMinAglFt = minAglFt?.clamp(0, 20000);
    final uri = _uri(FlightVisApiPaths.publicLiveTrails).replace(
      queryParameters: <String, String>{
        'lat': _formatCoordinate(lat),
        'lon': _formatCoordinate(lon),
        'radius_km': clampedRadius.toString(),
        if (clampedMinAglFt != null) 'min_agl_ft': clampedMinAglFt.toString(),
      },
    );
    final headers = <String, String>{};
    if (_acceptLanguage != null && _acceptLanguage!.isNotEmpty) {
      headers['Accept-Language'] = _acceptLanguage!;
    }
    if (ifNoneMatch != null && ifNoneMatch.isNotEmpty) {
      headers['If-None-Match'] = ifNoneMatch;
    }
    final response = await _http.get(uri, headers: headers);
    final responseEtag = response.headers['etag'];
    if (response.statusCode == 304) {
      return LiveTrailsResponse.notModified(etag: responseEtag ?? ifNoneMatch);
    }
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final rawFlights = body['flights'] as List<dynamic>? ?? const [];
    final flights = rawFlights
        .whereType<Map<String, dynamic>>()
        .map(LiveTrailFlight.fromJson)
        .toList(growable: false);
    final rawCaps = body['caps'];
    final caps = rawCaps is Map<String, dynamic>
        ? LiveTrailsCaps.fromJson(rawCaps)
        : null;
    return LiveTrailsResponse(
      flights: flights,
      caps: caps,
      etag: responseEtag,
    );
  }

  /// Updates a flight's visibility (`PATCH /api/flights/{slug}`).
  Future<Map<String, dynamic>> updateFlightVisibility(
    String slug, {
    required String visibility,
    bool? showPilotNamePublic,
  }) async {
    final response = await _http.patch(
      _uri(FlightVisApiPaths.flightBySlug(slug)),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'visibility': visibility,
        if (showPilotNamePublic != null)
          'show_pilot_name_public': showPilotNamePublic,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return _decodeJson(response);
  }

  static bool _hasValidCoordinates(double? lat, double? lon) {
    return lat != null &&
        lon != null &&
        lat.isFinite &&
        lon.isFinite &&
        lat >= -90.0 &&
        lat <= 90.0 &&
        lon >= -180.0 &&
        lon <= 180.0;
  }

  static String _formatCoordinate(double value) {
    final normalized = value.abs() < 1e-9 ? 0.0 : value;
    return normalized.toStringAsFixed(6);
  }

  /// Updates live trail length override (`PATCH /api/flights/{id}/trail`).
  /// Treats 409 (flight already ended) as a no-op.
  Future<int?> setFlightTrail(
    String flightId,
    int? trailMinutes, {
    String? deviceToken,
  }) async {
    final response = await _http.patch(
      _uri(FlightVisApiPaths.flightTrail(flightId)),
      headers: _headers(jsonBody: true, bearerOverride: deviceToken),
      body: jsonEncode({'trailMinutes': trailMinutes}),
    );
    if (response.statusCode == 409 || response.statusCode == 404) {
      return trailMinutes;
    }
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    return _parseTrailMinutes(body['trailMinutes']);
  }

  /// Ends flight; treats 409/404 as already ended (C-3).
  Future<void> endFlight(String flightId, {String? deviceToken}) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.flightEnd(flightId)),
      headers: _headers(bearerOverride: deviceToken),
    );
    if (response.statusCode == 409 || response.statusCode == 404) return;
    if (response.statusCode != 200) _throwForError(response);
  }

  void close() => _http.close();
}