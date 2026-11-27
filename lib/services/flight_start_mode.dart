import '../api/flight_vis_client.dart';
import '../state/checkin_gate.dart';

/// How "Iniciar vuelo" records a flight.
enum FlightStartMode {
  /// Record on-device only; zero server flight/upload requests.
  localOnly,

  /// Club broadcast flight via `POST /api/flights` + Traccar OsmAnd / batch ingest.
  clubBroadcast,

  /// Club-less / public-pilot broadcast via `POST /api/flights {mode: "personal"}`
  /// using a personal device token (no club check-in required).
  personalBroadcast,
}

/// Normalizes and validates a free-text aircraft registration for club-less
/// personal flights, matching server `normalize_free_tail` (`club/db.rs:35-51`):
/// trimmed, ASCII-uppercased, 1..=16 chars, only `A-Z`, `0-9`, `-`, with at
/// least one ASCII alphanumeric character.
///
/// Returns `null` when invalid.
String? normalizePersonalTail(String? raw) {
  if (raw == null) return null;
  final norm = raw.trim().toUpperCase();
  if (norm.isEmpty || norm.length > 16) return null;
  if (!RegExp(r'^[A-Z0-9-]+$').hasMatch(norm)) return null;
  if (!RegExp(r'[A-Z0-9]').hasMatch(norm)) return null;
  return norm;
}

/// Why a flight resolves to [FlightStartMode.localOnly].
enum LocalFlightReason {
  /// User is not signed in (or not an approved account).
  signedOut,

  /// Signed-in approved pilot without an active club check-in.
  noClubCheckin,
}

/// Resolution result for starting a flight from the Home Hub.
class FlightStartResolution {
  const FlightStartResolution({
    required this.mode,
    this.localReason,
  });

  final FlightStartMode mode;
  final LocalFlightReason? localReason;

  bool get isLocalOnly => mode == FlightStartMode.localOnly;
  bool get isClubBroadcast => mode == FlightStartMode.clubBroadcast;
  bool get isPersonalBroadcast => mode == FlightStartMode.personalBroadcast;
}

/// Single decision point mapping auth + check-in + mode selection to [FlightStartMode].
///
/// Rules:
/// - Signed-out / non-approved -> [FlightStartMode.localOnly] (`signedOut`).
/// - Signed-in club-less account (`pilot.isClublessAccount`) ->
///   [FlightStartMode.personalBroadcast] (no check-in required).
/// - Signed-in club member with an account session who explicitly selected
///   "Piloto público" (`preferPersonalBroadcast: true`) ->
///   [FlightStartMode.personalBroadcast] (no check-in required).
/// - Signed-in club member with valid check-in & available club ->
///   [FlightStartMode.clubBroadcast].
/// - Signed-in club member without check-in (or club unavailable) in club mode ->
///   [FlightStartMode.localOnly] (`noClubCheckin`).
FlightStartResolution resolveFlightStartMode({
  required PilotProfile? pilot,
  required CheckinGate checkinGate,
  bool clubUnavailable = false,
  bool preferPersonalBroadcast = false,
  bool hasAccountSession = false,
}) {
  final loggedIn = pilot != null && pilot.isApproved;
  if (!loggedIn) {
    return const FlightStartResolution(
      mode: FlightStartMode.localOnly,
      localReason: LocalFlightReason.signedOut,
    );
  }
  if (pilot.isClublessAccount) {
    return const FlightStartResolution(mode: FlightStartMode.personalBroadcast);
  }
  if (preferPersonalBroadcast && hasAccountSession) {
    return const FlightStartResolution(mode: FlightStartMode.personalBroadcast);
  }
  if (checkinGate.canStartFlight && !clubUnavailable) {
    return const FlightStartResolution(mode: FlightStartMode.clubBroadcast);
  }
  return const FlightStartResolution(
    mode: FlightStartMode.localOnly,
    localReason: LocalFlightReason.noClubCheckin,
  );
}
