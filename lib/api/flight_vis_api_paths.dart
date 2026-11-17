/// HTTP paths aligned with heavenly-tech/flight_vis `cursor/club-registry-phase2c-07f1`.
abstract final class FlightVisApiPaths {
  static const clubLogin = '/api/club/login';
  static const clubLogout = '/api/club/logout';
  static const clubMe = '/api/club/me';

  static const authMagicLink = '/api/club/auth/magic-link';
  static const authMagicConsume = '/api/club/auth/magic';

  static const webauthnLoginBegin = '/api/club/auth/webauthn/login/begin';
  static const webauthnLoginFinish = '/api/club/auth/webauthn/login/finish';

  /// Guest / unauthenticated device (client + CI mock; verify server ships handler).
  static const devicesAnonymous = '/api/devices/anonymous';

  static const checkin = '/api/checkin';
  static const meTails = '/api/me/tails';
  static const meDevices = '/api/me/devices';
  static const meFlights = '/api/me/flights';
  static const flights = '/api/flights';

  static String flightEnd(String flightId) => '/api/flights/$flightId/end';
  static String clubLanding(String slug, String token) =>
      '/api/c/$slug/q/${Uri.encodeComponent(token)}/landing';

  /// Optional multi-club read (when server exposes it); otherwise use [clubLanding].
  static String clubBySlug(String slug) => '/api/clubs/${Uri.encodeComponent(slug)}';
}