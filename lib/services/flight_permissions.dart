import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_config.dart';

/// Pilot tracking prerequisites (location, notifications, battery).
class FlightPermissionStatus {
  const FlightPermissionStatus({
    required this.fineLocationGranted,
    required this.backgroundLocationGranted,
    required this.notificationsGranted,
    required this.batteryUnrestricted,
  });

  final bool fineLocationGranted;
  final bool backgroundLocationGranted;
  final bool notificationsGranted;
  final bool batteryUnrestricted;

  /// Only foreground (fine) location is a hard requirement to start a flight.
  bool get canStartTracking => fineLocationGranted;

  /// True when any recommended tracking permission is missing (warn-only banner).
  bool get hasTrackingPermissionGaps => !allGranted;

  bool get allGranted =>
      fineLocationGranted &&
      backgroundLocationGranted &&
      notificationsGranted &&
      batteryUnrestricted;

  bool isGapGranted(PermissionGap gap) {
    return switch (gap) {
      PermissionGap.fineLocation => fineLocationGranted,
      PermissionGap.backgroundLocation => backgroundLocationGranted,
      PermissionGap.notifications => notificationsGranted,
      PermissionGap.battery => batteryUnrestricted,
    };
  }

  /// Missing gaps in walk-through order:
  /// fineLocation -> backgroundLocation -> notifications -> battery.
  List<PermissionGap> gaps() {
    final out = <PermissionGap>[];
    if (!fineLocationGranted) out.add(PermissionGap.fineLocation);
    if (!backgroundLocationGranted) out.add(PermissionGap.backgroundLocation);
    if (!notificationsGranted) out.add(PermissionGap.notifications);
    if (!batteryUnrestricted) out.add(PermissionGap.battery);
    return out;
  }
}

enum PermissionGap {
  fineLocation,
  backgroundLocation,
  notifications,
  battery,
}

/// Injectable permission abstraction for screens/widgets and tests.
abstract class FlightPermissionsClient {
  const FlightPermissionsClient();

  Future<FlightPermissionStatus> check();
  Future<bool> requestFineLocation();
  Future<bool> requestBackgroundLocation();
  Future<bool> requestNotifications();
  Future<bool> requestBatteryExemption();
  Future<bool> openSettings();
  Future<void> openGapSettings(PermissionGap gap);
}

class PlatformFlightPermissions extends FlightPermissionsClient {
  const PlatformFlightPermissions({
    MethodChannel? trackingChannel,
    @visibleForTesting bool? forceAndroid,
  })  : _trackingChannel = trackingChannel ?? _defaultTrackingChannel,
        _forceAndroid = forceAndroid;

  static const _defaultTrackingChannel =
      MethodChannel('cl.heavenly.flightvis/tracking');

  final MethodChannel _trackingChannel;
  final bool? _forceAndroid;

  bool get _isAndroid => _forceAndroid ?? Platform.isAndroid;

  Future<bool> _needsNotificationPermission() async {
    if (!_isAndroid) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 33;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkBatteryUnrestricted() async {
    if (_isAndroid) {
      try {
        final nativeResult = await _trackingChannel.invokeMethod<bool>(
          'isIgnoringBatteryOptimizations',
        );
        if (nativeResult != null) return nativeResult;
      } on MissingPluginException {
        // Fall through to permission_handler when the channel is unavailable.
      } on PlatformException {
        // Fall through to permission_handler.
      }
    }
    return Permission.ignoreBatteryOptimizations.isGranted;
  }

  Future<void> _openNotificationSettings() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    } on MissingPluginException {
      await openAppSettings();
    } on PlatformException {
      await openAppSettings();
    }
  }

  Future<void> _openBatteryOptimizationFlow() async {
    if (_isAndroid) {
      try {
        final opened = await _trackingChannel.invokeMethod<String>(
          'openBatteryOptimizationSettings',
        );
        if (opened != null && opened != 'none') {
          return;
        }
        await openAppSettings();
        return;
      } on MissingPluginException {
        final result = await Permission.ignoreBatteryOptimizations.request();
        if (!result.isGranted) {
          await openAppSettings();
        }
        return;
      } on PlatformException {
        await openAppSettings();
        return;
      }
    }
    final result = await Permission.ignoreBatteryOptimizations.request();
    if (!result.isGranted) {
      await openAppSettings();
    }
  }

  @override
  Future<FlightPermissionStatus> check() async {
    if (AppConfig.screenshotTest || kIsWeb) {
      return const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );
    }
    if (!_isAndroid && !Platform.isIOS) {
      return const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );
    }

    final fine = await Permission.locationWhenInUse.isGranted;
    final always = await Permission.locationAlways.isGranted;
    final notif = await _needsNotificationPermission()
        ? await Permission.notification.isGranted
        : true;
    final battery = await _checkBatteryUnrestricted();

    return FlightPermissionStatus(
      fineLocationGranted: fine,
      backgroundLocationGranted: always,
      notificationsGranted: notif,
      batteryUnrestricted: battery,
    );
  }

  @override
  Future<bool> requestFineLocation() async {
    if (AppConfig.screenshotTest) return true;
    final result = await Permission.locationWhenInUse.request();
    return result.isGranted;
  }

  @override
  Future<bool> requestBackgroundLocation() async {
    if (AppConfig.screenshotTest) return true;
    final result = await Permission.locationAlways.request();
    return result.isGranted;
  }

  @override
  Future<bool> requestNotifications() async {
    if (AppConfig.screenshotTest) return true;
    if (!await _needsNotificationPermission()) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  @override
  Future<bool> requestBatteryExemption() async {
    if (AppConfig.screenshotTest) return true;
    if (_isAndroid) {
      try {
        await _trackingChannel.invokeMethod<String>(
          'openBatteryOptimizationSettings',
        );
        return await _checkBatteryUnrestricted();
      } on MissingPluginException {
        final result = await Permission.ignoreBatteryOptimizations.request();
        return result.isGranted;
      } on PlatformException {
        return _checkBatteryUnrestricted();
      }
    }
    final result = await Permission.ignoreBatteryOptimizations.request();
    return result.isGranted;
  }

  @override
  Future<bool> openSettings() async {
    if (AppConfig.screenshotTest) return true;
    return openAppSettings();
  }

  @override
  Future<void> openGapSettings(PermissionGap gap) async {
    if (AppConfig.screenshotTest) return;
    switch (gap) {
      case PermissionGap.fineLocation:
        final current = await Permission.locationWhenInUse.status;
        if (!current.isPermanentlyDenied) {
          final res = await Permission.locationWhenInUse.request();
          if (res.isPermanentlyDenied) {
            await openAppSettings();
          }
        } else {
          await openAppSettings();
        }
      case PermissionGap.backgroundLocation:
        final current = await Permission.locationAlways.status;
        if (!current.isPermanentlyDenied) {
          final res = await Permission.locationAlways.request();
          if (res.isPermanentlyDenied) {
            await openAppSettings();
          }
        } else {
          await openAppSettings();
        }
      case PermissionGap.notifications:
        final current = await Permission.notification.status;
        if (!current.isPermanentlyDenied) {
          final res = await Permission.notification.request();
          if (res.isPermanentlyDenied) {
            await _openNotificationSettings();
          }
        } else {
          await _openNotificationSettings();
        }
      case PermissionGap.battery:
        await _openBatteryOptimizationFlow();
    }
  }
}

class FlightPermissions {
  static FlightPermissionsClient instance = const PlatformFlightPermissions();

  static Future<FlightPermissionStatus> check() => instance.check();

  static Future<FlightPermissionStatus> checkStatus() => instance.check();

  static Future<bool> requestFineLocation() => instance.requestFineLocation();

  static Future<bool> requestBackgroundLocation() =>
      instance.requestBackgroundLocation();

  static Future<bool> requestNotifications() => instance.requestNotifications();

  static Future<bool> requestBatteryExemption() =>
      instance.requestBatteryExemption();

  static Future<bool> openSettings() => instance.openSettings();

  static Future<void> openGapSettings(PermissionGap gap) =>
      instance.openGapSettings(gap);
}
