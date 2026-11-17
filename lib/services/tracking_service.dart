import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart';
import '../geolocation_service.dart';
import 'tracking_session.dart';

class TrackingService {
  static const screenshotTest = bool.fromEnvironment('FLIGHTVIS_SCREENSHOT_TEST');

  final TrackingSession _session = TrackingSession();
  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
  }) async {
    if (screenshotTest) return;
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
  }

  Future<bool> start() async {
    if (screenshotTest) return true;
    _session.resetLogCursor();
    try {
      await GeolocationService.tracker.start();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    if (screenshotTest) return;
    await GeolocationService.tracker.stop();
  }

  Future<bool> isTracking() async {
    if (screenshotTest) return true;
    return GeolocationService.tracker.isTracking();
  }

  Future<bool> ingestFailureRequiresStop() async {
    if (screenshotTest) return false;
    return _session.pollIngestRequiresStop();
  }
}