import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import 'own_trail_buffer.dart';

/// Protocol v1 constants aligned with `flight_vis` `/embed/3d?ui=mobile&v=1`
/// (`src/embed/bridge.ts`).
const int globeBridgeProtocolVersion = 1;
const String globeBridgeChannelName = 'FvBridge';
const String globeEmbedPath = '/embed/3d';
const int globeBridgeMaxFlights = 50;
const int globeBridgeMaxPointsPerFlight = 5000;
const int globeBridgeMaxFlightIdLength = 64;
const int globeBridgeMaxTailLength = 16;
const double globeBridgeMinAltMeters = -500.0;
const double globeBridgeMaxAltMeters = 20000.0;
const Duration globeBridgeThrottleInterval = Duration(seconds: 1);
const Duration globeBridgeReadyTimeout = Duration(seconds: 10);

final RegExp _controlCharsRe = RegExp(r'[\x00-\x1f\x7f]');

const Set<String> _debugLoopbackHosts = {
  'localhost',
  '127.0.0.1',
  '::1',
  '10.0.2.2',
  '10.0.3.2',
};

/// Returns `true` when [host] is a local loopback or Android emulator host.
bool isLoopbackOrEmulatorHost(String host) {
  final normalized = host.trim().toLowerCase();
  return _debugLoopbackHosts.contains(normalized);
}

/// Builds the exact embed URL `${baseUrl}/embed/3d?ui=mobile&v=1`.
///
/// Enforces `https` in all builds, permitting `http` ONLY for loopback/emulator
/// hosts when [allowDebugLoopbackHttp] is `true` (defaults to `!kReleaseMode`).
/// Returns `null` if [baseUrl] is invalid or violates scheme/host rules.
Uri? buildGlobeEmbedUri(
  String baseUrl, {
  bool allowDebugLoopbackHttp = !kReleaseMode,
}) {
  final normalized = AppConfig.normalizeBaseUrl(baseUrl);
  if (normalized.isEmpty) return null;
  final parsed = Uri.tryParse(normalized);
  if (parsed == null) return null;
  if (parsed.host.isEmpty || parsed.userInfo.isNotEmpty || parsed.hasFragment) {
    return null;
  }
  final scheme = parsed.scheme.toLowerCase();
  if (scheme == 'https') {
    // Always allowed with valid host.
  } else if (scheme == 'http' &&
      allowDebugLoopbackHttp &&
      isLoopbackOrEmulatorHost(parsed.host)) {
    // Debug-only emulator/loopback cleartext allowed to match debug network config.
  } else {
    return null;
  }
  return Uri(
    scheme: scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: globeEmbedPath,
    queryParameters: const <String, String>{
      'ui': 'mobile',
      'v': '$globeBridgeProtocolVersion',
    },
  );
}

/// Action taken by the 3D WebView `NavigationDelegate` for a requested URL.
enum GlobeNavigationAction {
  /// Exact embed origin + `/embed/3d` path: permit in WebView.
  allow,

  /// Disallowed navigation: block in WebView without launching any external app.
  prevent,

  /// External `https://` link (e.g. Cesium/Esri attribution credit link with
  /// `target="_blank"`): block in WebView and open via external browser.
  preventAndOpenExternal,
}

/// Returns `true` when [uri] matches [allowedEmbedUri]'s exact scheme, host,
/// effective port, and `/embed/3d` path (with no credentials or traversal).
bool isAllowedGlobeEmbedUri(Uri? uri, Uri allowedEmbedUri) {
  if (uri == null || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme.toLowerCase() != allowedEmbedUri.scheme.toLowerCase()) {
    return false;
  }
  if (uri.host.toLowerCase() != allowedEmbedUri.host.toLowerCase()) {
    return false;
  }
  if (uri.port != allowedEmbedUri.port) return false;
  if (uri.path != globeEmbedPath) return false;
  final segs = uri.pathSegments;
  return segs.length == 2 && segs[0] == 'embed' && segs[1] == '3d';
}

/// Evaluates a WebView navigation request against the strict embed navigation
/// lock. Only [allowedEmbedUri]'s exact scheme+host+port+`/embed/3d` path is
/// allowed inside the WebView; everything else is prevented, and external
/// `https://` links (such as `#credits` `target="_blank"` attribution links)
/// are routed to the external browser.
GlobeNavigationAction decideGlobeNavigation(
  Uri? target,
  Uri allowedEmbedUri, {
  bool isMainFrame = true,
}) {
  if (target == null || target.userInfo.isNotEmpty) {
    return GlobeNavigationAction.prevent;
  }
  if (isAllowedGlobeEmbedUri(target, allowedEmbedUri)) {
    return GlobeNavigationAction.allow;
  }
  if (isMainFrame &&
      target.scheme.toLowerCase() == 'https' &&
      target.host.isNotEmpty &&
      target.host.toLowerCase() != allowedEmbedUri.host.toLowerCase()) {
    return GlobeNavigationAction.preventAndOpenExternal;
  }
  return GlobeNavigationAction.prevent;
}

/// Returns `true` when an HTTP error reported by the WebView corresponds to the
/// main `/embed/3d` document load rather than a subresource (such as a tile).
bool isMainFrameGlobeHttpError(Uri? requestUri, Uri allowedEmbedUri) {
  if (requestUri == null) return true;
  return isAllowedGlobeEmbedUri(requestUri, allowedEmbedUri);
}

/// Sanitizes an identifier (`id`, `ownFlightId`, `flightId`) to bridge v1
/// limits: non-empty, `<= 64` chars, no ASCII control chars (`\x00-\x1f`, `\x7f`).
String? sanitizeGlobeBridgeId(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(_controlCharsRe, '').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= globeBridgeMaxFlightIdLength
      ? cleaned
      : cleaned.substring(0, globeBridgeMaxFlightIdLength);
}

/// Sanitizes an aircraft tail to bridge v1 limits: non-empty, `<= 16` chars,
/// no ASCII control chars.
String? sanitizeGlobeBridgeTail(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(_controlCharsRe, '').trim();
  if (cleaned.isEmpty) return null;
  return cleaned.length <= globeBridgeMaxTailLength
      ? cleaned
      : cleaned.substring(0, globeBridgeMaxTailLength);
}

/// Normalizes a Flutter locale language code to bridge v1's `"es" | "en"`.
String normalizeGlobeBridgeLang(String? languageCode) {
  final lower = (languageCode ?? '').trim().toLowerCase();
  return lower.startsWith('en') ? 'en' : 'es';
}

/// Single `[tMs, lat, lon, altMslMeters|null]` point for protocol v1.
///
/// Altitude unit & datum note:
/// - Both [LocalFix.altitude] (Android `Location.getAltitude()`) and
///   [LiveTrailPoint.altitude] (`GET /api/{me,public}/live-trails` `fixes.alt`)
///   are already in **meters** (no feet-to-meters conversion required).
/// - Datum: Android GPS reports WGS84 ellipsoidal height (HAE), and server
///   live-trails 4-tuples omit `alt_ref`. Because the app does not bundle an
///   EGM96 geoid grid, meters are forwarded directly (sanitizing non-finite
///   values to `null` and dropping finite values outside `[-500, 20000]` m to
///   match `src/embed/bridge.ts`), leaving the ~27 m Santiago undulation caveat
///   until protocol v1.1 adds an optional `altRef` field.
class GlobeBridgePoint {
  const GlobeBridgePoint({
    required this.timeMs,
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
  });

  final int timeMs;
  final double latitude;
  final double longitude;
  final double? altitudeMeters;

  List<num?> toJsonList() => <num?>[
        timeMs,
        latitude,
        longitude,
        altitudeMeters,
      ];

  /// Validates coordinates and altitude range matching `src/embed/bridge.ts`.
  static GlobeBridgePoint? tryCreate({
    required int timeMs,
    required double latitude,
    required double longitude,
    double? altitudeMeters,
  }) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90.0 ||
        latitude > 90.0 ||
        longitude < -180.0 ||
        longitude > 180.0) {
      return null;
    }
    double? cleanAlt;
    if (altitudeMeters != null && altitudeMeters.isFinite) {
      if (altitudeMeters < globeBridgeMinAltMeters ||
          altitudeMeters > globeBridgeMaxAltMeters) {
        return null;
      }
      cleanAlt = altitudeMeters;
    }
    return GlobeBridgePoint(
      timeMs: timeMs,
      latitude: latitude,
      longitude: longitude,
      altitudeMeters: cleanAlt,
    );
  }
}

/// Single aircraft entry in a bridge v1 `flights` message.
class GlobeBridgeFlight {
  const GlobeBridgeFlight({
    required this.id,
    required this.tail,
    required this.tailSource,
    required this.layer,
    required this.points,
    this.otherClub = false,
  });

  final String id;
  final String tail;

  /// `'club'` or `'pilot'`.
  final String tailSource;

  /// `'own'`, `'club'`, or `'public'`.
  final String layer;

  /// Optional PR #54 flag passed through when `true`.
  final bool otherClub;

  final List<GlobeBridgePoint> points;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tail': tail,
        'tailSource': tailSource == 'pilot' ? 'pilot' : 'club',
        'layer': (layer == 'own' || layer == 'club' || layer == 'public')
            ? layer
            : 'public',
        if (otherClub) 'otherClub': true,
        'points': [for (final p in points) p.toJsonList()],
      };
}

/// Builds the capped, sanitized list of [GlobeBridgeFlight]s from the data
/// `TrackingMapCard` already holds (own trail buffer + filtered remote flights).
///
/// Enforces protocol v1 caps (`<= 50` flights, `<= 5000` points per flight,
/// `id <= 64`, `tail <= 16`, valid coordinates & altitude range).
List<GlobeBridgeFlight> buildGlobeBridgeFlights({
  required bool showOwn,
  String? ownFlightId,
  String? ownTail,
  String ownTailSource = 'club',
  List<LocalFix> ownTrailPoints = const [],
  LocalFix? ownLatestFix,
  List<LiveTrailFlight> remoteFlights = const [],
  bool includeClub = true,
  bool includePublic = true,
}) {
  final out = <GlobeBridgeFlight>[];
  final seenIds = <String>{};

  if (showOwn) {
    final effectiveOwnPoints = ownTrailPoints.isNotEmpty
        ? ownTrailPoints
        : (ownLatestFix != null ? <LocalFix>[ownLatestFix] : const <LocalFix>[]);
    final cleanTail = sanitizeGlobeBridgeTail(ownTail);
    final cleanId = sanitizeGlobeBridgeId(ownFlightId) ?? 'own';
    if (effectiveOwnPoints.isNotEmpty && cleanTail != null) {
      final pts = <GlobeBridgePoint>[];
      final startIdx = effectiveOwnPoints.length > globeBridgeMaxPointsPerFlight
          ? effectiveOwnPoints.length - globeBridgeMaxPointsPerFlight
          : 0;
      for (var i = startIdx; i < effectiveOwnPoints.length; i++) {
        final f = effectiveOwnPoints[i];
        final p = GlobeBridgePoint.tryCreate(
          timeMs: f.timeMs,
          latitude: f.latitude,
          longitude: f.longitude,
          altitudeMeters: f.altitude,
        );
        if (p != null) pts.add(p);
      }
      if (pts.isNotEmpty) {
        out.add(
          GlobeBridgeFlight(
            id: cleanId,
            tail: cleanTail,
            tailSource: ownTailSource == 'pilot' ? 'pilot' : 'club',
            layer: 'own',
            points: List<GlobeBridgePoint>.unmodifiable(pts),
          ),
        );
        seenIds.add(cleanId);
      }
    }
  }

  for (final remote in remoteFlights) {
    if (out.length >= globeBridgeMaxFlights) break;
    if (remote.isPublic && !includePublic) continue;
    if (!remote.isPublic && !includeClub) continue;

    final cleanId = sanitizeGlobeBridgeId(remote.flightId);
    final cleanTail = sanitizeGlobeBridgeTail(remote.tail);
    if (cleanId == null || cleanTail == null) continue;
    if (!seenIds.add(cleanId)) continue;

    final rawPoints = remote.trailMinutes == 0
        ? (remote.latestPoint != null
            ? <LiveTrailPoint>[remote.latestPoint!]
            : const <LiveTrailPoint>[])
        : remote.points;
    if (rawPoints.isEmpty) continue;

    final startIdx = rawPoints.length > globeBridgeMaxPointsPerFlight
        ? rawPoints.length - globeBridgeMaxPointsPerFlight
        : 0;
    final pts = <GlobeBridgePoint>[];
    for (var i = startIdx; i < rawPoints.length; i++) {
      final rp = rawPoints[i];
      final p = GlobeBridgePoint.tryCreate(
        timeMs: rp.timeMs,
        latitude: rp.latitude,
        longitude: rp.longitude,
        altitudeMeters: rp.altitude,
      );
      if (p != null) pts.add(p);
    }
    if (pts.isEmpty) continue;

    out.add(
      GlobeBridgeFlight(
        id: cleanId,
        tail: cleanTail,
        tailSource: remote.tailSource == 'pilot' ? 'pilot' : 'club',
        layer: remote.isPublic ? 'public' : 'club',
        otherClub: remote.otherClub,
        points: List<GlobeBridgePoint>.unmodifiable(pts),
      ),
    );
  }

  return List<GlobeBridgeFlight>.unmodifiable(out);
}

/// Pure encoder for Flutter -> WebView protocol v1 messages.
abstract final class GlobeBridgeEncoder {
  static Map<String, dynamic> init({
    required String lang,
    String? ownFlightId,
  }) {
    final cleanOwnId = sanitizeGlobeBridgeId(ownFlightId);
    return <String, dynamic>{
      'type': 'init',
      'protocol': globeBridgeProtocolVersion,
      'lang': normalizeGlobeBridgeLang(lang),
      if (cleanOwnId != null) 'ownFlightId': cleanOwnId,
    };
  }

  static Map<String, dynamic> flights({
    required String mode,
    required List<GlobeBridgeFlight> flights,
  }) {
    assert(mode == 'full' || mode == 'delta');
    final capped = flights.length <= globeBridgeMaxFlights
        ? flights
        : flights.sublist(0, globeBridgeMaxFlights);
    final serialized = <Map<String, dynamic>>[];
    for (final f in capped) {
      final cleanId = sanitizeGlobeBridgeId(f.id);
      final cleanTail = sanitizeGlobeBridgeTail(f.tail);
      if (cleanId == null || cleanTail == null) continue;
      final pts = f.points.length <= globeBridgeMaxPointsPerFlight
          ? f.points
          : f.points.sublist(f.points.length - globeBridgeMaxPointsPerFlight);
      serialized.add(
        GlobeBridgeFlight(
          id: cleanId,
          tail: cleanTail,
          tailSource: f.tailSource,
          layer: f.layer,
          otherClub: f.otherClub,
          points: pts,
        ).toJson(),
      );
    }
    return <String, dynamic>{
      'type': 'flights',
      'mode': mode,
      'flights': serialized,
    };
  }

  static Map<String, dynamic> follow({
    required bool on,
    String? flightId,
  }) {
    final cleanId = sanitizeGlobeBridgeId(flightId);
    return <String, dynamic>{
      'type': 'follow',
      'on': on,
      if (cleanId != null) 'flightId': cleanId,
    };
  }

  static Map<String, dynamic> recenter() =>
      const <String, dynamic>{'type': 'recenter'};

  static Map<String, dynamic> overview() =>
      const <String, dynamic>{'type': 'overview'};

  static Map<String, dynamic> pause() =>
      const <String, dynamic>{'type': 'pause'};

  static Map<String, dynamic> resume() =>
      const <String, dynamic>{'type': 'resume'};

  /// Wraps [payload] in `window.fvBridge.receive(<json string literal>)` using
  /// double `jsonEncode` so quotes, backslashes, newlines, and Unicode line
  /// terminators (`U+2028`, `U+2029`) are strictly escaped.
  static String toReceiveJavaScript(Map<String, dynamic> payload) {
    final jsonPayload = jsonEncode(payload);
    final jsStringLiteral = jsonEncode(jsonPayload)
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
    return 'window.fvBridge.receive($jsStringLiteral)';
  }
}

/// Computes minimal `full` vs `delta` bridge updates from successive snapshots.
class GlobeFlightSyncTracker {
  bool _hasSentFull = false;
  final Map<String, _SyncedFlightMeta> _synced = <String, _SyncedFlightMeta>{};

  bool get hasSentFull => _hasSentFull;

  void reset() {
    _hasSentFull = false;
    _synced.clear();
  }

  /// Returns the next `flights` message (`full` or `delta`) required to bring
  /// the WebView from its last synced state to [current], or `null` if nothing
  /// changed.
  Map<String, dynamic>? buildNextMessage(List<GlobeBridgeFlight> current) {
    final capped = current.length <= globeBridgeMaxFlights
        ? current
        : current.sublist(0, globeBridgeMaxFlights);

    if (!_hasSentFull) {
      _commit(capped);
      return GlobeBridgeEncoder.flights(mode: 'full', flights: capped);
    }

    final currentIds = <String>{for (final f in capped) f.id};
    // Any removed flight requires a `full` snapshot so the embed deletes it.
    for (final prevId in _synced.keys) {
      if (!currentIds.contains(prevId)) {
        _commit(capped);
        return GlobeBridgeEncoder.flights(mode: 'full', flights: capped);
      }
    }

    final deltaFlights = <GlobeBridgeFlight>[];
    for (final flight in capped) {
      final prev = _synced[flight.id];
      if (prev == null) {
        deltaFlights.add(flight);
        continue;
      }
      final metadataChanged = prev.tail != flight.tail ||
          prev.tailSource != flight.tailSource ||
          prev.layer != flight.layer ||
          prev.otherClub != flight.otherClub;
      final currentFirstMs =
          flight.points.isEmpty ? null : flight.points.first.timeMs;
      final currentLastMs =
          flight.points.isEmpty ? null : flight.points.last.timeMs;
      final windowShrankOrRewound = flight.points.length < prev.pointCount ||
          (prev.firstTimeMs != null &&
              currentFirstMs != null &&
              currentFirstMs > prev.firstTimeMs!) ||
          (prev.lastTimeMs != null &&
              currentLastMs != null &&
              currentLastMs < prev.lastTimeMs!);
      if (metadataChanged || windowShrankOrRewound) {
        _commit(capped);
        return GlobeBridgeEncoder.flights(mode: 'full', flights: capped);
      }

      if (prev.lastTimeMs == null) {
        if (flight.points.isNotEmpty) {
          deltaFlights.add(flight);
        }
      } else {
        final newPoints = <GlobeBridgePoint>[
          for (final pt in flight.points)
            if (pt.timeMs > prev.lastTimeMs!) pt,
        ];
        if (newPoints.isNotEmpty) {
          deltaFlights.add(
            GlobeBridgeFlight(
              id: flight.id,
              tail: flight.tail,
              tailSource: flight.tailSource,
              layer: flight.layer,
              otherClub: flight.otherClub,
              points: List<GlobeBridgePoint>.unmodifiable(newPoints),
            ),
          );
        }
      }
    }

    if (deltaFlights.isEmpty) return null;
    _commit(capped);
    return GlobeBridgeEncoder.flights(mode: 'delta', flights: deltaFlights);
  }

  void _commit(List<GlobeBridgeFlight> flights) {
    _hasSentFull = true;
    _synced
      ..clear()
      ..addEntries(
        flights.map(
          (f) => MapEntry<String, _SyncedFlightMeta>(
            f.id,
            _SyncedFlightMeta(
              tail: f.tail,
              tailSource: f.tailSource,
              layer: f.layer,
              otherClub: f.otherClub,
              pointCount: f.points.length,
              firstTimeMs: f.points.isEmpty ? null : f.points.first.timeMs,
              lastTimeMs: f.points.isEmpty ? null : f.points.last.timeMs,
            ),
          ),
        ),
      );
  }
}

class _SyncedFlightMeta {
  const _SyncedFlightMeta({
    required this.tail,
    required this.tailSource,
    required this.layer,
    required this.otherClub,
    required this.pointCount,
    required this.firstTimeMs,
    required this.lastTimeMs,
  });

  final String tail;
  final String tailSource;
  final String layer;
  final bool otherClub;
  final int pointCount;
  final int? firstTimeMs;
  final int? lastTimeMs;
}

/// Enforces `<= 1 message/s` per message `kind` with coalescing trailing flush
/// so rapid updates never burst the WebView bridge and never lose the latest
/// state.
class GlobeBridgeThrottler {
  GlobeBridgeThrottler({
    this.minInterval = globeBridgeThrottleInterval,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration minInterval;
  final DateTime Function() _clock;
  final Map<String, DateTime> _lastSentAt = <String, DateTime>{};
  final Map<String, Timer> _pendingTimers = <String, Timer>{};
  final Map<String, void Function()> _pendingActions =
      <String, void Function()>{};
  bool _disposed = false;

  /// Runs [action] immediately if at least [minInterval] elapsed since the
  /// previous send of [kind]; otherwise schedules/coalesces a single trailing
  /// execution at `lastSentAt + minInterval`.
  void schedule(String kind, void Function() action) {
    if (_disposed) return;
    final now = _clock();
    final last = _lastSentAt[kind];
    if (last == null || now.difference(last) >= minInterval) {
      _pendingTimers.remove(kind)?.cancel();
      _pendingActions.remove(kind);
      _lastSentAt[kind] = now;
      action();
      return;
    }
    _pendingActions[kind] = action;
    if (_pendingTimers.containsKey(kind)) return;
    final wait = minInterval - now.difference(last);
    _pendingTimers[kind] = Timer(wait, () {
      _pendingTimers.remove(kind);
      final pending = _pendingActions.remove(kind);
      if (_disposed || pending == null) return;
      _lastSentAt[kind] = _clock();
      pending();
    });
  }

  void dispose() {
    _disposed = true;
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    _pendingActions.clear();
  }
}

/// Inbound WebView -> Flutter events emitted over `FvBridge.postMessage(json)`.
sealed class GlobeInboundEvent {
  const GlobeInboundEvent();
}

class GlobeReadyEvent extends GlobeInboundEvent {
  const GlobeReadyEvent({required this.protocol, this.version});

  final int protocol;
  final String? version;
}

class GlobeFollowChangedEvent extends GlobeInboundEvent {
  const GlobeFollowChangedEvent({required this.on, this.reason});

  final bool on;
  final String? reason;
}

class GlobeErrorEvent extends GlobeInboundEvent {
  const GlobeErrorEvent({required this.code});

  final String code;
}

class GlobePerfEvent extends GlobeInboundEvent {
  const GlobePerfEvent({required this.quality});

  final int quality;
}

/// Defensively parses raw JSON emitted by `FvBridge.postMessage`.
/// Returns `null` for malformed JSON, unknown types, or invalid field shapes.
GlobeInboundEvent? parseGlobeInboundMessage(String raw) {
  if (raw.isEmpty) return null;
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final type = decoded['type'];
  if (type is! String) return null;

  switch (type) {
    case 'ready':
      final proto = decoded['protocol'];
      if (proto is! num || !proto.isFinite || proto != proto.truncateToDouble()) {
        return null;
      }
      final version = decoded['version'];
      return GlobeReadyEvent(
        protocol: proto.toInt(),
        version: version is String ? version : null,
      );
    case 'followChanged':
      final on = decoded['on'];
      if (on is! bool) return null;
      final reason = decoded['reason'];
      return GlobeFollowChangedEvent(
        on: on,
        reason: reason is String ? reason : null,
      );
    case 'error':
      final code = decoded['code'];
      if (code is! String || code.trim().isEmpty) return null;
      return GlobeErrorEvent(code: code.trim());
    case 'perf':
      final quality = decoded['quality'];
      if (quality is! num || !quality.isFinite) return null;
      return GlobePerfEvent(quality: quality.toInt());
    default:
      return null;
  }
}
