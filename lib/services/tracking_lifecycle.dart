/// Pure tracking stop/resume rules (C-3).
bool checkinExpired({required int? expiresAtMs, required int nowMs}) {
  if (expiresAtMs == null) return false;
  return nowMs >= expiresAtMs;
}

/// [serverSaysActive] is `null` when the server could not be queried.
bool shouldResumeTracking({
  required String? activeFlightId,
  required bool? serverSaysActive,
  required int? checkinExpiresAtMs,
  required int nowMs,
}) {
  if (activeFlightId == null || activeFlightId.isEmpty) return false;
  if (checkinExpired(expiresAtMs: checkinExpiresAtMs, nowMs: nowMs)) return false;
  if (serverSaysActive == false) return false;
  if (serverSaysActive == null) return false;
  return true;
}

/// SDK diagnostic lines that mean ingest must stop (401 / 400 no active flight).
bool ingestLogRequiresStop(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('401') || lower.contains('unauthorized')) return true;
  if (lower.contains('no active flight')) return true;
  if (lower.contains('400') &&
      (lower.contains('bad request') || lower.contains('no active'))) {
    return true;
  }
  return false;
}