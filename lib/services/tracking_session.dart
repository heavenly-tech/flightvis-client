import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../geolocation_service.dart';
import 'tracking_lifecycle.dart';

/// Resolves whether stored active-flight state may resume GPS uploads.
class TrackingSession {
  TrackingSession({TraccarClientSdk? tracker})
      : _tracker = tracker ?? GeolocationService.tracker;

  final TraccarClientSdk _tracker;
  int _logCursor = 0;

  void resetLogCursor() => _logCursor = 0;

  Future<bool> pollIngestRequiresStop() async {
    final logs = await _tracker.getLogs();
    if (logs.length < _logCursor) {
      _logCursor = 0;
    }
    final slice = logs.length > _logCursor ? logs.sublist(_logCursor) : const <LogEntry>[];
    _logCursor = logs.length;
    return slice.any((e) => ingestLogRequiresStop(e.message));
  }
}