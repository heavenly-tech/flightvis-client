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

  /// Why [canStartFlight] is false (client-side gate before POST /api/flights).
  CheckinStartBlock? startBlock() {
    if (!hasCheckin) return CheckinStartBlock.missing;
    if (isExpired) return CheckinStartBlock.expired;
    return null;
  }
}

enum CheckinStartBlock { missing, expired }