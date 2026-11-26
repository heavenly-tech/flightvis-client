import 'package:flutter/services.dart';

import '../map/own_trail_buffer.dart';

/// Reads the device's last-known location without starting continuous tracking
/// or making network requests.
abstract class DeviceLocationProvider {
  const DeviceLocationProvider();

  Future<LocalFix?> getLastKnownLocation();
}

/// Platform implementation backed by Android `LocationManager.getLastKnownLocation`
/// over the existing `cl.heavenly.flightvis/tracking` MethodChannel.
class PlatformDeviceLocationProvider extends DeviceLocationProvider {
  const PlatformDeviceLocationProvider({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  static const _defaultChannel =
      MethodChannel('cl.heavenly.flightvis/tracking');

  final MethodChannel _channel;

  @override
  Future<LocalFix?> getLastKnownLocation() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getLastKnownLocation');
      if (raw is Map<Object?, Object?>) {
        return LocalFix.fromMap(raw);
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Injectable in-memory fake for unit and widget tests.
class FakeDeviceLocationProvider extends DeviceLocationProvider {
  FakeDeviceLocationProvider({this.location});

  LocalFix? location;
  int callCount = 0;

  @override
  Future<LocalFix?> getLastKnownLocation() async {
    callCount++;
    return location;
  }
}
