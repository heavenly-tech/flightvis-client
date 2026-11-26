import 'package:flutter/foundation.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart' show AppConfig;
import '../geolocation_service.dart';
import 'checkin_expiry_alarm.dart';
import 'local_fix_source.dart';
import 'tracking_session.dart';

class TrackingService {
  TrackingService({TraccarClientSdk? tracker, LocalFixSource? fixSource}) {
    final resolved = tracker ?? GeolocationService.tracker;
    _tracker = resolved;
    _session = TrackingSession(tracker: resolved);
    _fixSource = fixSource ?? const PlatformLocalFixSource();
  }

  late final TraccarClientSdk _tracker;
  late final TrackingSession _session;
  late final LocalFixSource _fixSource;
  int? _checkinExpiresAtMs;

  LocalFixSource get fixSource => _fixSource;

  @visibleForTesting
  TraccarClientSdk get trackerForTest => _tracker;

  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
    int? checkinExpiresAtMs,
  }) async {
    if (AppConfig.screenshotTest) return;
    final token = deviceToken.trim();
    if (token.isEmpty) {
      throw ArgumentError.value(deviceToken, 'deviceToken', 'must not be empty');
    }
    _checkinExpiresAtMs = checkinExpiresAtMs;
    final config = Config(
      serverUrl: AppConfig.osmandUrl(baseUrl),
      // OsmAnd `id=` must be the server-issued device token, never the raw device id.
      deviceId: token,
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
    // `init` is idempotent and ignores subsequent configs; `setConfig` ensures
    // newly issued or rotated device tokens are always applied before `start()`.
    await _tracker.init(config);
    await _tracker.setConfig(config);
  }

  Future<bool> start() async {
    if (AppConfig.screenshotTest) return true;
    await _session.syncCursorFromExistingLogs();
    try {
      await _tracker.start();
    } catch (_) {
      return false;
    }
    await _fixSource.startRecording();
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
    try {
      await _fixSource.clear();
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