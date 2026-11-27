import '../api/flight_vis_client.dart';

/// Pure tracking stop/resume rules (C-3).
bool checkinExpired({required int? expiresAtMs, required int nowMs}) {
  if (expiresAtMs == null) return false;
  return nowMs >= expiresAtMs;
}

/// [serverSaysActive]: `true` = active on server; `false` = explicitly ended (including
/// 404/409); `null` = unknown (offline / timeout) — resume when check-in is still valid
/// (or always for personal flights, which have no club check-in gate).
///
/// Always returns `false` when [hasSession] is `false` (M-24 defence in depth).
bool shouldResumeTracking({
  required String? activeFlightId,
  required bool? serverSaysActive,
  required int? checkinExpiresAtMs,
  required int nowMs,
  bool hasSession = true,
  bool isPersonalFlight = false,
}) {
  if (!hasSession) return false;
  if (activeFlightId == null || activeFlightId.isEmpty) return false;
  if (!isPersonalFlight &&
      checkinExpired(expiresAtMs: checkinExpiresAtMs, nowMs: nowMs)) {
    return false;
  }
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
///
/// Note: HTTP 429 (`rate limited`) intentionally returns `false` — active
/// tracking continues and undelivered fixes are queued for store-and-forward
/// retry with backoff.
bool ingestLogRequiresStop(String message) {
  final match = _uploadResponseLine.firstMatch(message.trim());
  if (match == null) return false;
  final code = int.parse(match.group(1)!);
  return code == 400 || code == 401 || code == 403;
}

/// True when a Traccar SDK log line indicates HTTP 429 rate limiting.
bool ingestLogIsRateLimited(String message) {
  final match = _uploadResponseLine.firstMatch(message.trim());
  if (match == null) return false;
  return int.parse(match.group(1)!) == 429;
}

/// True when a Traccar SDK log line indicates a transient upload failure or
/// offline condition (so fixes should be captured into the store-and-forward
/// batch upload queue).
bool ingestLogIndicatesFailure(String message) {
  final trimmed = message.trim();
  final match = _uploadResponseLine.firstMatch(trimmed);
  if (match != null) {
    final code = int.parse(match.group(1)!);
    return code == 429 || code >= 500;
  }
  final lower = trimmed.toLowerCase();
  return lower.startsWith('upload error') ||
      lower.startsWith('upload failed') ||
      lower.startsWith('offline');
}

/// True when a Traccar SDK log line indicates a confirmed live 2xx upload.
bool ingestLogIndicatesSuccess(String message) {
  final match = _uploadResponseLine.firstMatch(message.trim());
  if (match == null) return false;
  final code = int.parse(match.group(1)!);
  return code >= 200 && code < 300;
}

/// True when Traccar SDK reports connectivity returned.
bool ingestLogIndicatesNetworkRestored(String message) =>
    message.trim().toLowerCase().contains('network restored');