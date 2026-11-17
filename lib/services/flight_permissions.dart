import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

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

class FlightPermissions {
  static const screenshotTest = bool.fromEnvironment('FLIGHTVIS_SCREENSHOT_TEST');

  static Future<bool> _needsNotificationPermission() async {
    if (!Platform.isAndroid) return false;
    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt >= 33;
  }

  static Future<FlightPermissionStatus> check() async {
    if (screenshotTest || kIsWeb) {
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

  static Future<bool> requestFineLocation() async {
    if (screenshotTest) return true;
    final result = await Permission.locationWhenInUse.request();
    return result.isGranted;
  }

  static Future<bool> requestBackgroundLocation() async {
    if (screenshotTest) return true;
    final result = await Permission.locationAlways.request();
    return result.isGranted;
  }

  static Future<bool> requestNotifications() async {
    if (screenshotTest) return true;
    if (!await _needsNotificationPermission()) return true;
    final result = await Permission.notification.request();
    return result.isGranted;
  }

  static Future<bool> requestBatteryExemption() async {
    if (screenshotTest) return true;
    final result = await Permission.ignoreBatteryOptimizations.request();
    return result.isGranted;
  }

  static Future<void> openGapSettings(PermissionGap gap) async {
    if (screenshotTest) return;
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