import 'dart:async';

import 'package:app_links/app_links.dart';

import '../util/flight_deep_link.dart';

typedef DeepLinkHandler = Future<void> Function(ParsedDeepLink link);

/// Subscribes to App Links for production host paths.
class DeepLinkDispatcher {
  DeepLinkDispatcher({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  Future<void> bind(DeepLinkHandler onLink) async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) {
      final parsed = FlightDeepLink.parseUri(initial);
      if (parsed != null) await onLink(parsed);
    }
    await _sub?.cancel();
    _sub = _appLinks.uriLinkStream.listen((uri) async {
      final parsed = FlightDeepLink.parseUri(uri);
      if (parsed != null) await onLink(parsed);
    });
  }

  Future<void> dispose() async => _sub?.cancel();
}