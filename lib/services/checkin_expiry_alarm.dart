import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';

/// Schedules a native alarm to stop GPS when check-in expires (app may be killed).
class CheckinExpiryAlarm {
  static const _channel = MethodChannel('cl.heavenly.flightvis/tracking');

  static Future<void> scheduleStopAt(int? expiresAtMs) async {
    if (AppConfig.screenshotTest || kIsWeb) return;
    if (expiresAtMs == null) {
      await cancel();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (expiresAtMs <= now) {
      await cancel();
      return;
    }
    try {
      await _channel.invokeMethod<void>('scheduleCheckinExpiryStop', expiresAtMs);
    } on MissingPluginException {
      // Desktop / unsupported.
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('CheckinExpiryAlarm: schedule failed (${e.code}): ${e.message}');
        debugPrint('$st');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('CheckinExpiryAlarm: schedule failed: $e');
        debugPrint('$st');
      }
    }
  }

  static Future<void> cancel() async {
    if (AppConfig.screenshotTest || kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('cancelCheckinExpiryStop');
    } on MissingPluginException {
      // Desktop / unsupported.
    } on PlatformException catch (e, st) {
      if (kDebugMode) {
        debugPrint('CheckinExpiryAlarm: cancel failed (${e.code}): ${e.message}');
        debugPrint('$st');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('CheckinExpiryAlarm: cancel failed: $e');
        debugPrint('$st');
      }
    }
  }
}