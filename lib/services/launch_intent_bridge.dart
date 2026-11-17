import 'package:flutter/services.dart';

import '../util/flight_deep_link.dart';

/// Android `intent://` launch data and intent extras from [MainActivity].
class LaunchIntentBridge {
  LaunchIntentBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cl.heavenly.flightvis/deeplink');

  final MethodChannel _channel;

  Future<ParsedDeepLink?> readInitialDeepLink() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getLaunchDeepLink');
      if (raw == null) return null;
      final extras = raw['extras'] as Map<dynamic, dynamic>?;
      final extrasMap = extras?.map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      );
      final uriStr = raw['uri'] as String?;
      if (uriStr != null && uriStr.isNotEmpty) {
        final uri = Uri.tryParse(uriStr);
        if (uri != null) {
          final parsed = FlightDeepLink.parseIncoming(uri, extras: extrasMap);
          if (parsed != null) return parsed;
        }
      }
      return FlightDeepLink.parseIncoming(Uri(), extras: extrasMap);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}