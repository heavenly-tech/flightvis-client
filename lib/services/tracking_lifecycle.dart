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

final _uploadResponseLine = RegExp(r'^Upload response (\d{3})$');

/// SDK log line that means ingest must stop (exact `Upload response NNN` only).
bool ingestLogRequiresStop(String message) {
  final match = _uploadResponseLine.firstMatch(message.trim());
  if (match == null) return false;
  final code = int.parse(match.group(1)!);
  return code == 400 || code == 401 || code == 403;
}