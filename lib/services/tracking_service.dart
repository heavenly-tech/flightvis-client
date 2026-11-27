import 'package:flutter/foundation.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import '../app_config.dart' show AppConfig;
import '../geolocation_service.dart';
import 'checkin_expiry_alarm.dart';
import 'local_fix_source.dart';
import 'native_fix_queue.dart';
import 'tracking_session.dart';

class TrackingService {
  TrackingService({
    TraccarClientSdk? tracker,
    LocalFixSource? fixSource,
    NativeFixQueueBridge? nativeFixQueue,
  }) {
    final resolved = tracker ?? GeolocationService.tracker;
    _tracker = resolved;
    _session = TrackingSession(tracker: resolved);
    _fixSource = fixSource ?? const PlatformLocalFixSource();
    _nativeFixQueue = nativeFixQueue ?? const NativeFixQueueBridge();
  }

  late final TraccarClientSdk _tracker;
  late final TrackingSession _session;
  late final LocalFixSource _fixSource;
  late final NativeFixQueueBridge _nativeFixQueue;
  int? _checkinExpiresAtMs;
  String? _activeFlightId;
  String _activeFlightMode = 'club';

  LocalFixSource get fixSource => _fixSource;
  NativeFixQueueBridge get nativeFixQueue => _nativeFixQueue;

  @visibleForTesting
  TraccarClientSdk get trackerForTest => _tracker;

  Future<void> initForFlight({
    required String baseUrl,
    required String deviceToken,
    int? checkinExpiresAtMs,
    String? flightId,
    String flightMode = 'club',
  }) async {
    if (AppConfig.screenshotTest) return;
    final token = deviceToken.trim();
    if (token.isEmpty) {
      throw ArgumentError.value(deviceToken, 'deviceToken', 'must not be empty');
    }
    _checkinExpiresAtMs = checkinExpiresAtMs;
    final trimmedFlightId = flightId?.trim();
    _activeFlightId =
        (trimmedFlightId != null && trimmedFlightId.isNotEmpty)
            ? trimmedFlightId
            : null;
    _activeFlightMode = flightMode == 'personal' ? 'personal' : 'club';
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
      // Store-and-forward offline buffering is owned by Dart `FixUploadQueueStore`
      // + `FixUploadWorker` (`POST /api/ingest` in <=100-fix batches with
      // Retry-After backoff and 413 splitting), backed by native JSONL
      // persistence (`NativeFixQueueStore`) while the Dart isolate is dead.
      buffer: false,
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
    final flightId = _activeFlightId;
    if (flightId != null) {
      await _nativeFixQueue.setActiveFlight(
        flightId: flightId,
        flightMode: _activeFlightMode,
      );
    }
    try {
      await _tracker.start();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TrackingService.start failed: $e\n$st');
      }
      await _nativeFixQueue.clearActiveFlight();
      return false;
    }
    await _fixSource.startRecording();
    await CheckinExpiryAlarm.scheduleStopAt(_checkinExpiresAtMs);
    return true;
  }

  Future<void> stop() async {
    if (AppConfig.screenshotTest) return;
    _activeFlightId = null;
    try {
      await _nativeFixQueue.clearActiveFlight();
    } catch (_) {}
    try {
      await _tracker.stop();
    } catch (_) {}
    try {
      await CheckinExpiryAlarm.cancel();
    } catch (_) {}
    try {
      await _fixSource.clear();
    } catch (_) {}
  }

  Future<bool> isTracking() async {
    if (AppConfig.screenshotTest) return true;
    return _tracker.isTracking();
  }

  Future<TrackingLogPollResult> pollIngestStatus() async {
    if (AppConfig.screenshotTest) return TrackingLogPollResult.empty;
    return _session.pollIngestStatus();
  }

  Future<bool> ingestFailureRequiresStop() async {
    if (AppConfig.screenshotTest) return false;
    return _session.pollIngestRequiresStop();
  }
}
