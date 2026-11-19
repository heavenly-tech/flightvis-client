import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../geolocation_service.dart';
import 'tracking_log_cursor.dart';

/// Resolves whether stored active-flight state may resume GPS uploads.
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

  Future<bool> pollIngestRequiresStop() async {
    final logs = await _tracker.getLogs();
    final newEntries = logEntriesAfter(logs, _lastProcessedLogTimeMs);
    if (newEntries.isEmpty) return false;
    _lastProcessedLogTimeMs = newestLogTimestampMs(newEntries);
    return ingestStopInEntries(newEntries);
  }
}