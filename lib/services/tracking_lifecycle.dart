import '../api/flight_vis_client.dart';

/// Pure tracking stop/resume rules (C-3).
bool checkinExpired({required int? expiresAtMs, required int nowMs}) {
  if (expiresAtMs == null) return false;
  return nowMs >= expiresAtMs;
}

/// [serverSaysActive]: `true` = active on server; `false` = explicitly ended (including
/// 404/409); `null` = unknown (offline / timeout) — resume when check-in is still valid.
bool shouldResumeTracking({
  required String? activeFlightId,
  required bool? serverSaysActive,
  required int? checkinExpiresAtMs,
  required int nowMs,
}) {
  if (activeFlightId == null || activeFlightId.isEmpty) return false;
  if (checkinExpired(expiresAtMs: checkinExpiresAtMs, nowMs: nowMs)) return false;
  if (serverSaysActive == false) return false;
  return true;
}

/// Maps errors from the active-flight server probe (M-5).
bool? serverFlightActiveFromError(Object error) {
  if (error is FlightVisException) {
    final code = error.statusCode;
    if (code == 404 || code == 409) return false;
  }
  return null;
}

final _uploadResponseLine = RegExp(r'^Upload response (\d{3})$');

/// SDK log line that means ingest must stop (exact `Upload response NNN` only).
bool ingestLogRequiresStop(String message) {
  final match = _uploadResponseLine.firstMatch(message.trim());
  if (match == null) return false;
  final code = int.parse(match.group(1)!);
  return code == 400 || code == 401 || code == 403;
}