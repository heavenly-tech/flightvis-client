import 'dart:convert';

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
  });

  final String message;
  final int? statusCode;
  final Map<String, dynamic>? body;

  /// Machine reason code from server (`body['reason']`, e.g. `used_claim`, `expired_qr`).
  final String? reason;

  /// Optional human-readable message returned by server (`body['message']`).
  final String? serverMessage;

  @override
  String toString() => message;
}

int? _parseTrailMinutes(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return null;
}

/// Pilot profile from login (no `licenseNo`) or `/api/club/me` (includes `licenseNo`).
class PilotProfile {
  PilotProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.status,
    required this.role,
    this.licenseNo,
    this.clubTrailMinutesDefault,
  });

  final String id;
  final String name;
  final String email;
  final String status;
  final String role;
  final String? licenseNo;
  final int? clubTrailMinutesDefault;

  factory PilotProfile.fromJson(
    Map<String, dynamic> json, {
    int? clubTrailMinutesDefault,
  }) =>
      PilotProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        role: json['role'] as String,
        licenseNo: json['licenseNo'] as String?,
        clubTrailMinutesDefault: clubTrailMinutesDefault ??
            _parseTrailMinutes(json['clubTrailMinutesDefault']),
      );

  bool get isApproved => status == 'approved';
  bool get isGuest => status == 'guest';
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

  /// Raw device id minted by server on bearerless check-in (never sent as OsmAnd `id=`).
  final String? deviceId;

  /// Device token minted or rotated by server (`json['token']`), used as Bearer and OsmAnd `id=`.
  final String? deviceToken;

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

class MyFlightSummary {
  MyFlightSummary({required this.id, required this.tail, required this.status});

  final String id;
  final String tail;
  final String status;

  bool get isActive => status == 'active';

  factory MyFlightSummary.fromJson(Map<String, dynamic> json) => MyFlightSummary(
        id: json['id'] as String,
        tail: json['tail'] as String? ?? '',
        status: json['status'] as String? ?? '',
      );
}

class StartFlightResult {
  StartFlightResult({
    required this.id,
    required this.visibility,
    required this.showPilotNamePublic,
    this.trailMinutes,
    this.hasTrailMinutes = false,
  });

  final String id;
  final String visibility;
  final bool showPilotNamePublic;
  final int? trailMinutes;
  final bool hasTrailMinutes;

  factory StartFlightResult.fromJson(Map<String, dynamic> json) =>
      StartFlightResult(
        id: json['id'] as String,
        visibility: json['visibility'] as String,
        showPilotNamePublic: json['showPilotNamePublic'] as bool? ?? false,
        trailMinutes: _parseTrailMinutes(json['trailMinutes']),
        hasTrailMinutes: json.containsKey('trailMinutes'),
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

/// Another aircraft's live trail returned by `GET /api/me/live-trails`.
class LiveTrailFlight {
  const LiveTrailFlight({
    required this.flightId,
    required this.tail,
    required this.layer,
    required this.trailMinutes,
    required this.points,
  });

  final String flightId;
  final String tail;
  final String layer;
  final int trailMinutes;
  final List<LiveTrailPoint> points;

  bool get isPublic => layer == 'public';
  bool get isClub => layer == 'club';
  LiveTrailPoint? get latestPoint => points.isEmpty ? null : points.last;

  factory LiveTrailFlight.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>? ?? const [];
    final parsedPoints = <LiveTrailPoint>[];
    for (final entry in rawPoints) {
      final point = LiveTrailPoint.fromJsonList(entry);
      if (point != null) parsedPoints.add(point);
    }
    return LiveTrailFlight(
      flightId: json['flightId'] as String? ?? '',
      tail: json['tail'] as String? ?? '',
      layer: json['layer'] as String? ?? 'club',
      trailMinutes: _parseTrailMinutes(json['trailMinutes']) ?? 0,
      points: List<LiveTrailPoint>.unmodifiable(parsedPoints),
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

/// Typed HTTP client for heavenly-tech/flight_vis club APIs (PR #15).
class FlightVisClient {
  FlightVisClient({
    required this.baseUrl,
    http.Client? httpClient,
    String? sessionId,
    String? deviceToken,
    String? clubSlug,
  })  : _http = httpClient ?? http.Client(),
        _sessionId = sessionId,
        _deviceToken = deviceToken,
        _clubSlug = clubSlug;

  static const passkeyRpId = 'flight.heavenly.cl';

  String baseUrl;
  final http.Client _http;
  String? _sessionId;
  String? _deviceToken;
  String? _clubSlug;
  String? _acceptLanguage;
  int? _clubTrailMinutesDefault;

  String? get sessionId => _sessionId;
  String? get deviceToken => _deviceToken;
  int? get clubTrailMinutesDefault => _clubTrailMinutesDefault;
  bool get hasSession => _sessionId != null && _sessionId!.isNotEmpty;
  bool get hasDeviceToken => _deviceToken != null && _deviceToken!.isNotEmpty;

  void setSessionId(String? value) => _sessionId = value;
  void setDeviceToken(String? value) => _deviceToken = value;
  void setClubTrailMinutesDefault(int? value) => _clubTrailMinutesDefault = value;
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

  Map<String, String> _headers({bool jsonBody = false}) {
    final headers = <String, String>{
      if (jsonBody) 'Content-Type': 'application/json',
    };
    if (_sessionId != null && _sessionId!.isNotEmpty) {
      headers['Cookie'] = 'fv_club_session=$_sessionId';
    }
    if (_deviceToken != null && _deviceToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_deviceToken';
    }
    if (_acceptLanguage != null && _acceptLanguage!.isNotEmpty) {
      headers['Accept-Language'] = _acceptLanguage!;
    }
    return headers;
  }

  String? _sessionFromResponse(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null) return null;
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('fv_club_session=')) {
        final value = trimmed.substring('fv_club_session='.length).split(';').first;
        if (value.isNotEmpty) return value;
      }
    }
    for (final segment in raw.split(';')) {
      if (segment.trim().startsWith('fv_club_session=')) {
        return segment.trim().substring('fv_club_session='.length);
      }
    }
    return null;
  }

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
    throw FlightVisException(
      error,
      statusCode: response.statusCode,
      body: body,
      reason: reason,
      serverMessage: serverMessage,
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
    final loginPilot = PilotProfile.fromJson(body['pilot'] as Map<String, dynamic>);
    final me = await meProfile();
    return me ?? loginPilot;
  }

  Future<PilotProfile?> meProfile() async {
    if (!hasSession) return null;
    final response = await _http.get(_uri(FlightVisApiPaths.clubMe), headers: _headers());
    if (response.statusCode == 401) {
      _clubTrailMinutesDefault = null;
      return null;
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
    return PilotProfile.fromJson(
      pilotMap,
      clubTrailMinutesDefault: clubDefault,
    );
  }

  Future<void> logout({String? installId}) async {
    if (!hasSession) {
      _sessionId = null;
      _clubTrailMinutesDefault = null;
      return;
    }
    final response = await _http.post(
      _uri(FlightVisApiPaths.clubLogout),
      headers: _headers(jsonBody: installId != null),
      body: installId == null ? null : jsonEncode({'installId': installId}),
    );
    if (response.statusCode != 200) _throwForError(response);
    _sessionId = null;
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
      return PilotProfile.fromJson(pilot);
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
      return PilotProfile.fromJson(pilot);
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
  }) async {
    if (clubSlug != null && clubSlug.isNotEmpty) {
      _clubSlug = clubSlug;
    }
    final trimmedDeviceId = deviceId?.trim();
    final response = await _http.post(
      _uri(FlightVisApiPaths.checkin),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'token': kioskToken.trim(),
        if (trimmedDeviceId != null && trimmedDeviceId.isNotEmpty)
          'deviceId': trimmedDeviceId,
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
  }) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.flights),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'tail': tail,
        'visibility': visibility,
        'show_pilot_name_public': showPilotNamePublic,
        if (sendTrail && trailMinutes != null) 'trailMinutes': trailMinutes,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return StartFlightResult.fromJson(_decodeJson(response));
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

  Future<List<MyFlightSummary>> myFlights() async {
    if (!hasSession) return const [];
    final response = await _http.get(
      _uri(FlightVisApiPaths.meFlights),
      headers: _headers(),
    );
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    return (body['flights'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(MyFlightSummary.fromJson)
        .toList();
  }

  /// Returns true if [flightId] is still `active` on the server (session required).
  Future<bool> isFlightActiveOnServer(String flightId) async {
    final flights = await myFlights();
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
  Future<int?> setFlightTrail(String flightId, int? trailMinutes) async {
    final response = await _http.patch(
      _uri(FlightVisApiPaths.flightTrail(flightId)),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'trailMinutes': trailMinutes}),
    );
    if (response.statusCode == 409) return trailMinutes;
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    return _parseTrailMinutes(body['trailMinutes']);
  }

  /// Ends flight; treats 409/404 as already ended (C-3).
  Future<void> endFlight(String flightId) async {
    final response = await _http.post(
      _uri(FlightVisApiPaths.flightEnd(flightId)),
      headers: _headers(),
    );
    if (response.statusCode == 409 || response.statusCode == 404) return;
    if (response.statusCode != 200) _throwForError(response);
  }

  void close() => _http.close();
}