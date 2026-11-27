import '../api/flight_vis_client.dart';
import '../state/checkin_gate.dart';

/// How "Iniciar vuelo" records a flight.
///
/// Structured so a future "club-less app F" PR can add `personalBroadcast`
/// without rewriting call sites.
enum FlightStartMode {
  /// Record on-device only; zero server flight/upload requests.
  localOnly,

  /// Club broadcast flight via `POST /api/flights` + Traccar OsmAnd ingest.
  clubBroadcast,

  // TODO(club-less-app-f): Add `personalBroadcast` once non-club server
  // flights are supported for signed-in pilots without a club check-in.
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
}

/// Single decision point mapping auth + check-in state to [FlightStartMode].
FlightStartResolution resolveFlightStartMode({
  required PilotProfile? pilot,
  required CheckinGate checkinGate,
}) {
  final loggedIn = pilot != null && pilot.isApproved;
  if (loggedIn && checkinGate.canStartFlight) {
    return const FlightStartResolution(mode: FlightStartMode.clubBroadcast);
  }
  if (loggedIn) {
    return const FlightStartResolution(
      mode: FlightStartMode.localOnly,
      localReason: LocalFlightReason.noClubCheckin,
    );
  }
  return const FlightStartResolution(
    mode: FlightStartMode.localOnly,
    localReason: LocalFlightReason.signedOut,
  );
}
