import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart';
import '../geolocation_service.dart';

class TrackingService {
  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
  }) async {
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
    try {
      await GeolocationService.tracker.start();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() => GeolocationService.tracker.stop();

  Future<bool> isTracking() => GeolocationService.tracker.isTracking();
}