import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../geolocation_service.dart';
import 'tracking_lifecycle.dart';
import 'tracking_log_cursor.dart';

/// Summarized outcome of newly appended Traccar SDK diagnostic log entries.
class TrackingLogPollResult {
  const TrackingLogPollResult({
    this.requiresStop = false,
    this.sawFailure = false,
    this.sawRateLimited = false,
    this.sawSuccess = false,
    this.sawNetworkRestored = false,
  });

  static const empty = TrackingLogPollResult();

  final bool requiresStop;
  final bool sawFailure;
  final bool sawRateLimited;
  final bool sawSuccess;
  final bool sawNetworkRestored;
}

/// Resolves whether stored active-flight state may resume GPS uploads and
/// observes live Traccar upload outcomes for store-and-forward fallback.
class TrackingSession {
  TrackingSession({TraccarClientSdk? tracker})
      : _tracker = tracker ?? GeolocationService.tracker;

  final TraccarClientSdk _tracker;
  int? _lastProcessedLogTimeMs;

  /// Ignore existing SDK log tail (e.g. prior flight's `Upload response 400`).
  Future<void> syncCursorFromExistingLogs() async {
    final logs = await _tracker.getLogs();
    _lastProcessedLogTimeMs = newestLogTimestampMs(logs);
  }

  Future<TrackingLogPollResult> pollIngestStatus() async {
    final logs = await _tracker.getLogs();
    final newEntries = logEntriesAfter(logs, _lastProcessedLogTimeMs);
    if (newEntries.isEmpty) return TrackingLogPollResult.empty;
    _lastProcessedLogTimeMs = newestLogTimestampMs(newEntries);
    var requiresStop = false;
    var sawFailure = false;
    var sawRateLimited = false;
    var sawSuccess = false;
    var sawNetworkRestored = false;
    for (final entry in newEntries) {
      final msg = entry.message;
      if (ingestLogRequiresStop(msg)) requiresStop = true;
      if (ingestLogIsRateLimited(msg)) sawRateLimited = true;
      if (ingestLogIndicatesFailure(msg)) sawFailure = true;
      if (ingestLogIndicatesSuccess(msg)) sawSuccess = true;
      if (ingestLogIndicatesNetworkRestored(msg)) sawNetworkRestored = true;
    }
    return TrackingLogPollResult(
      requiresStop: requiresStop,
      sawFailure: sawFailure,
      sawRateLimited: sawRateLimited,
      sawSuccess: sawSuccess,
      sawNetworkRestored: sawNetworkRestored,
    );
  }

  Future<bool> pollIngestRequiresStop() async =>
      (await pollIngestStatus()).requiresStop;
}