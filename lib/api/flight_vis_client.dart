import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_config.dart';

class FlightVisException implements Exception {
  FlightVisException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final Map<String, dynamic>? body;

  @override
  String toString() => message;
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
  });

  final String id;
  final String name;
  final String email;
  final String status;
  final String role;
  final String? licenseNo;

  factory PilotProfile.fromJson(Map<String, dynamic> json) => PilotProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        role: json['role'] as String,
        licenseNo: json['licenseNo'] as String?,
      );

  bool get isApproved => status == 'approved';
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

  factory ClubSummary.fromJson(Map<String, dynamic> json) => ClubSummary(
        slug: json['slug'] as String? ?? json['id'] as String? ?? '',
        name: json['name'] as String? ?? json['slug'] as String? ?? '',
      );
}

class CheckinResult {
  CheckinResult({
    required this.ok,
    this.expiresAtUtc,
    this.clubSlug,
    this.clubName,
  });

  final bool ok;
  final DateTime? expiresAtUtc;
  final String? clubSlug;
  final String? clubName;

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
    return CheckinResult(
      ok: json['ok'] == true,
      expiresAtUtc: expires,
      clubSlug: slug,
      clubName: name,
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
    final token = json['token'] as String?;
    if (token == null || token.isEmpty) {
      throw FlightVisException('device token missing in response');
    }
    return DeviceRegistration(
      id: json['id'] as String,
      token: token,
      label: json['label'] as String?,
    );
  }
}

class StartFlightResult {
  StartFlightResult({
    required this.id,
    required this.visibility,
    required this.showPilotNamePublic,
  });

  final String id;
  final String visibility;
  final bool showPilotNamePublic;

  factory StartFlightResult.fromJson(Map<String, dynamic> json) =>
      StartFlightResult(
        id: json['id'] as String,
        visibility: json['visibility'] as String,
        showPilotNamePublic: json['showPilotNamePublic'] as bool? ?? false,
      );
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

  String? get sessionId => _sessionId;
  String? get deviceToken => _deviceToken;

  void setSessionId(String? value) => _sessionId = value;
  void setDeviceToken(String? value) => _deviceToken = value;
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

  String _scoped(String legacyPath, String scopedTail) {
    final slug = _clubSlug;
    if (slug != null && slug.isNotEmpty) {
      return '/api/clubs/${Uri.encodeComponent(slug)}/$scopedTail';
    }
    return legacyPath;
  }

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
    final error = body?['error']?.toString() ?? 'HTTP ${response.statusCode}';
    throw FlightVisException(error, statusCode: response.statusCode, body: body);
  }

  /// Login then enrich profile from `GET /api/club/me` (`licenseNo`).
  Future<PilotProfile> login(String email, String password) async {
    final response = await _http.post(
      _uri('/api/club/login'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
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
    final response = await _http.get(_uri('/api/club/me'), headers: _headers());
    if (response.statusCode != 200) _throwForError(response);
    final body = _decodeJson(response);
    final pilot = body['pilot'];
    if (pilot == null) return null;
    return PilotProfile.fromJson(pilot as Map<String, dynamic>);
  }

  Future<void> logout() async {
    final response = await _http.post(
      _uri('/api/club/logout'),
      headers: _headers(),
    );
    if (response.statusCode != 200) _throwForError(response);
    _sessionId = null;
  }

  Future<ClubSummary> fetchClub(String slug) async {
    final response = await _http.get(
      _uri('/api/clubs/${Uri.encodeComponent(slug)}'),
      headers: _headers(),
    );
    if (response.statusCode != 200) _throwForError(response);
    return ClubSummary.fromJson(_decodeJson(response));
  }

  Future<void> sendMagicLink(String email) async {
    final response = await _http.post(
      _uri('/api/auth/magic/send'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'email': email.trim()}),
    );
    if (response.statusCode != 200) _throwForError(response);
  }

  Future<PilotProfile> completeMagicLink(String token) async {
    final response = await _http.post(
      _uri('/api/auth/magic/complete'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'token': token.trim()}),
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

  Future<Map<String, dynamic>> passkeyLoginOptions() async {
    final response = await _http.post(
      _uri('/api/auth/passkey/login/options'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'rpId': passkeyRpId}),
    );
    if (response.statusCode != 200) _throwForError(response);
    return _decodeJson(response);
  }

  Future<PilotProfile> passkeyLoginVerify(String credentialJson) async {
    final response = await _http.post(
      _uri('/api/auth/passkey/login/verify'),
      headers: _headers(jsonBody: true),
      body: credentialJson,
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

  Future<CheckinResult> checkin(String kioskToken, {String? clubSlug}) async {
    if (clubSlug != null && clubSlug.isNotEmpty) {
      _clubSlug = clubSlug;
    }
    final response = await _http.post(
      _uri(_scoped('/api/checkin', 'checkin')),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'token': kioskToken.trim()}),
    );
    if (response.statusCode != 200) _throwForError(response);
    final result = CheckinResult.fromJson(_decodeJson(response));
    if (!result.ok) {
      throw FlightVisException('check-in failed');
    }
    _clubSlug = result.clubSlug ?? clubSlug ?? _clubSlug;
    return result;
  }

  Future<List<TailOption>> tails() async {
    final response = await _http.get(_uri(_scoped('/api/me/tails', 'me/tails')), headers: _headers());
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
  }) async {
    final response = await _http.post(
      _uri(_scoped('/api/flights', 'flights')),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'tail': tail,
        'visibility': visibility,
        'show_pilot_name_public': showPilotNamePublic,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return StartFlightResult.fromJson(_decodeJson(response));
  }

  /// Guest device registration (`POST /api/devices/anonymous`).
  Future<DeviceRegistration> registerAnonymousDevice({
    String label = 'Android',
    String? locale,
  }) async {
    final response = await _http.post(
      _uri('/api/devices/anonymous'),
      headers: _headers(jsonBody: true),
      body: jsonEncode({
        'label': label,
        if (locale != null && locale.isNotEmpty) 'locale': locale,
      }),
    );
    if (response.statusCode != 200) _throwForError(response);
    return DeviceRegistration.fromJson(_decodeJson(response));
  }

  /// Logged-in pilot device (`POST /api/me/devices` or club-scoped).
  Future<DeviceRegistration> registerDevice({String label = 'Android'}) async {
    final response = await _http.post(
      _uri(_scoped('/api/me/devices', 'me/devices')),
      headers: _headers(jsonBody: true),
      body: jsonEncode({'label': label}),
    );
    if (response.statusCode != 200) _throwForError(response);
    return DeviceRegistration.fromJson(_decodeJson(response));
  }

  Future<void> endFlight(String flightId) async {
    final response = await _http.post(
      _uri(_scoped('/api/flights/$flightId/end', 'flights/$flightId/end')),
      headers: _headers(),
    );
    if (response.statusCode != 200) _throwForError(response);
  }

  void close() => _http.close();
}