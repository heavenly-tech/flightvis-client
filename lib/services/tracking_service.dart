import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart' show AppConfig;
import '../geolocation_service.dart';
import 'checkin_expiry_alarm.dart';
import 'tracking_session.dart';

class TrackingService {
  final TrackingSession _session = TrackingSession();
  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
    int? checkinExpiresAtMs,
  }) async {
    if (AppConfig.screenshotTest) return;
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
    await GeolocationService.tracker.init(config);
    await CheckinExpiryAlarm.scheduleStopAt(checkinExpiresAtMs);
  }

  Future<bool> start() async {
    if (AppConfig.screenshotTest) return true;
    _session.resetLogCursor();
    try {
      await GeolocationService.tracker.start();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    if (AppConfig.screenshotTest) return;
    await CheckinExpiryAlarm.cancel();
    await GeolocationService.tracker.stop();
  }

  Future<bool> isTracking() async {
    if (AppConfig.screenshotTest) return true;
    return GeolocationService.tracker.isTracking();
  }

  Future<bool> ingestFailureRequiresStop() async {
    if (AppConfig.screenshotTest) return false;
    return _session.pollIngestRequiresStop();
  }
}