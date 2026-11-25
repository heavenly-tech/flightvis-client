import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
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

  bool get canStartTracking => backgroundLocationGranted;

  /// True when background location or unrestricted battery exemption is missing.
  bool get hasTrackingPermissionGaps =>
      !backgroundLocationGranted || !batteryUnrestricted;

  bool get allGranted =>
      fineLocationGranted &&
      backgroundLocationGranted &&
      notificationsGranted &&
      batteryUnrestricted;

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
  const PlatformFlightPermissions();

  Future<bool> _needsNotificationPermission() async {
    if (!Platform.isAndroid) return false;
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
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
    if (!Platform.isAndroid && !Platform.isIOS) {
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
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;

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
      case PermissionGap.backgroundLocation:
        await openAppSettings();
      case PermissionGap.notifications:
        await openAppSettings();
      case PermissionGap.battery:
        await Permission.ignoreBatteryOptimizations.request();
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
