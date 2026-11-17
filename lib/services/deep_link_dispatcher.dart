import 'dart:async';

import 'package:app_links/app_links.dart';

import '../util/flight_deep_link.dart';
import 'launch_intent_bridge.dart';

typedef DeepLinkHandler = Future<void> Function(ParsedDeepLink link);

/// Subscribes to App Links and Android launch intents (https + `intent://` fallback).
class DeepLinkDispatcher {
  DeepLinkDispatcher({
    AppLinks? appLinks,
    LaunchIntentBridge? launchBridge,
  })  : _appLinks = appLinks ?? AppLinks(),
        _launchBridge = launchBridge ?? LaunchIntentBridge();

  final AppLinks _appLinks;
  final LaunchIntentBridge _launchBridge;
  StreamSubscription<Uri>? _sub;

  Future<void> bind(DeepLinkHandler onLink) async {
    final fromPlatform = await _launchBridge.readInitialDeepLink();
    if (fromPlatform != null) await onLink(fromPlatform);

    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      final parsed = FlightDeepLink.parseIncoming(initial);
      if (parsed != null) await onLink(parsed);
    }
    await _sub?.cancel();
    _sub = _appLinks.uriLinkStream.listen((uri) async {
      final parsed = FlightDeepLink.parseIncoming(uri);
      if (parsed != null) await onLink(parsed);
    });
  }

  Future<void> dispose() async => _sub?.cancel();
}

/// Integration / debug injection (not used in production UI).
class DeepLinkTestHooks {
  static Future<void> Function(ParsedDeepLink link)? handler;
  static Future<void> dispatch(ParsedDeepLink link) async {
    await handler?.call(link);
  }
}