import '../app_config.dart';

/// Whether the pilot may start a club flight (valid check-in, not expired).
class CheckinGate {
  CheckinGate({required this.expiresAtMs, required this.nowMs});

  final int? expiresAtMs;
  final int nowMs;

  bool get hasCheckin => expiresAtMs != null;

  bool get isExpired =>
      expiresAtMs != null && nowMs >= expiresAtMs!;

  bool get canStartFlight => hasCheckin && !isExpired;

  Duration? remaining() {
    if (expiresAtMs == null) return null;
    final diff = expiresAtMs! - nowMs;
    if (diff <= 0) return Duration.zero;
    return Duration(milliseconds: diff);
  }

  /// After a successful POST /api/checkin the server does not return expiry;
  /// assume the club default (30 minutes unless configured server-side).
  static int defaultExpiresAtMs(int nowMs) =>
      nowMs + AppConfig.defaultCheckinValidMinutes * 60 * 1000;

  String? startBlockedReason() {
    if (!hasCheckin) return 'Scan the club check-in QR before starting a flight.';
    if (isExpired) return 'Check-in expired. Scan the club screen QR again.';
    return null;
  }
}