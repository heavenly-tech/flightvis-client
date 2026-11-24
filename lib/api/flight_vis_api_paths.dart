/// HTTP paths aligned with heavenly-tech/flight_vis @ bd79692 (`contract_routes.rs`).
abstract final class FlightVisApiPaths {
  static const clubLogin = '/api/club/login';
  static const clubLogout = '/api/club/logout';
  static const clubMe = '/api/club/me';

  /// Client contract aliases (I-5) — mounted via `contract_router` on the server.
  static const authMagicSend = '/api/auth/magic/send';
  static const authMagicComplete = '/api/auth/magic/complete';
  static const passkeyLoginOptions = '/api/auth/passkey/login/options';
  static const passkeyLoginVerify = '/api/auth/passkey/login/verify';
  static const devicesAnonymous = '/api/devices/anonymous';
  static const clubAuthClaim = '/api/club/auth/claim';

  /// Browser magic consume (email links); app deep links use [authMagicComplete].
  static const clubAuthMagicConsume = '/api/club/auth/magic';

  static const checkin = '/api/checkin';
  static const meTails = '/api/me/tails';
  static const meDevices = '/api/me/devices';
  static const meFlights = '/api/me/flights';
  static const flights = '/api/flights';

  static String flightEnd(String flightId) => '/api/flights/$flightId/end';
  static String clubBySlug(String slug) => '/api/clubs/${Uri.encodeComponent(slug)}';
  static String checkinLanding(String slug, String token) =>
      '/api/c/${Uri.encodeComponent(slug)}/q/${Uri.encodeComponent(token)}/landing';
}