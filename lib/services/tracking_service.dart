import 'package:flutter/foundation.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart' show AppConfig;
import '../geolocation_service.dart';
import 'checkin_expiry_alarm.dart';
import 'tracking_session.dart';

class TrackingService {
  TrackingService({TraccarClientSdk? tracker}) {
    final resolved = tracker ?? GeolocationService.tracker;
    _tracker = resolved;
    _session = TrackingSession(tracker: resolved);
  }

  late final TraccarClientSdk _tracker;
  late final TrackingSession _session;
  int? _checkinExpiresAtMs;

  @visibleForTesting
  TraccarClientSdk get trackerForTest => _tracker;

  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
    int? checkinExpiresAtMs,
  }) async {
    if (AppConfig.screenshotTest) return;
    _checkinExpiresAtMs = checkinExpiresAtMs;
    final config = Config(
      serverUrl: AppConfig.osmandUrl(baseUrl),
      deviceId: deviceToken,
      location: const LocationConfig(
        accuracy: Accuracy.high,
        distanceMeters: 0,
        intervalSeconds: 1,
        angleDegrees: 0,
        heartbeatIntervalSeconds: 0,
        stopDetection: false,
      ),
      wakeLock: true,
      buffer: true,
      preferPlatformProviders: false,
    );
    await _tracker.init(config);
  }

  Future<bool> start() async {
    if (AppConfig.screenshotTest) return true;
    await _session.syncCursorFromExistingLogs();
    try {
      await _tracker.start();
    } catch (_) {
      return false;
    }
    await CheckinExpiryAlarm.scheduleStopAt(_checkinExpiresAtMs);
    return true;
  }

  Future<void> stop() async {
    if (AppConfig.screenshotTest) return;
    try {
      await CheckinExpiryAlarm.cancel();
    } catch (_) {}
    try {
      await _tracker.stop();
    } catch (_) {}
  }

  Future<bool> isTracking() async {
    if (AppConfig.screenshotTest) return true;
    return _tracker.isTracking();
  }

  Future<bool> ingestFailureRequiresStop() async {
    if (AppConfig.screenshotTest) return false;
    return _session.pollIngestRequiresStop();
  }
}