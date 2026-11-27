import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/globe_bridge.dart';

/// Reason the 3D globe view automatically fell back to the 2D map.
enum GlobeFallbackReason {
  offline,
  loadFailed,
  readyTimeout,
  webglUnavailable,
  protocolMismatch,
  bridgeError,
  invalidUrl,
}

/// Optional callback launching external `https://` credit links in the browser.
typedef GlobeExternalUrlLauncher = Future<bool> Function(Uri uri);

/// Optional connectivity check invoked before opening the 3D view.
typedef GlobeConnectivityCheck = Future<bool> Function();

/// Thin abstraction over `webview_flutter`'s [WebViewController] + [WebViewWidget]
/// so widget and golden tests can inject deterministic fakes without a real
/// platform WebView.
abstract class GlobeWebViewController {
  Future<void> setJavaScriptMode(JavaScriptMode mode);

  Future<void> setBackgroundColor(Color color);

  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  });

  Future<void> setNavigationDelegate({
    required FutureOr<NavigationDecision> Function(NavigationRequest request)
        onNavigationRequest,
    required void Function(WebResourceError error) onWebResourceError,
    required void Function(HttpResponseError error) onHttpError,
  });

  /// Loads [uri] with ZERO extra headers and ZERO cookies.
  Future<void> loadRequest(Uri uri);

  Future<void> runJavaScript(String javaScript);

  Widget buildView({
    required Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers,
  });

  void dispose();
}

/// Production [GlobeWebViewController] backed by `webview_flutter`.
///
/// Security invariants:
/// - Never touches `WebViewCookieManager`.
/// - Never sends auth/session/device headers on [loadRequest].
/// - Never enables file access or loads local files/assets.
/// - Only registers the single `FvBridge` channel requested by [GlobeView].
class WebViewFlutterGlobeController implements GlobeWebViewController {
  WebViewFlutterGlobeController({WebViewController? controller})
      : _controller = controller ?? WebViewController();

  final WebViewController _controller;
  String? _channelName;
  bool _disposed = false;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) {
    if (_disposed) return Future<void>.value();
    return _controller.setJavaScriptMode(mode);
  }

  @override
  Future<void> setBackgroundColor(Color color) {
    if (_disposed) return Future<void>.value();
    return _controller.setBackgroundColor(color);
  }

  @override
  Future<void> addJavaScriptChannel(
    String name, {
    required void Function(String message) onMessageReceived,
  }) {
    if (_disposed) return Future<void>.value();
    _channelName = name;
    return _controller.addJavaScriptChannel(
      name,
      onMessageReceived: (JavaScriptMessage msg) {
        if (!_disposed) onMessageReceived(msg.message);
      },
    );
  }

  @override
  Future<void> setNavigationDelegate({
    required FutureOr<NavigationDecision> Function(NavigationRequest request)
        onNavigationRequest,
    required void Function(WebResourceError error) onWebResourceError,
    required void Function(HttpResponseError error) onHttpError,
  }) {
    if (_disposed) return Future<void>.value();
    return _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (req) {
          if (_disposed) return NavigationDecision.prevent;
          return onNavigationRequest(req);
        },
        onWebResourceError: (err) {
          if (!_disposed) onWebResourceError(err);
        },
        onHttpError: (err) {
          if (!_disposed) onHttpError(err);
        },
      ),
    );
  }

  @override
  Future<void> loadRequest(Uri uri) {
    if (_disposed) return Future<void>.value();
    // Explicitly omit headers: no cookies, bearer tokens, or session IDs ever
    // enter the WebView.
    return _controller.loadRequest(uri);
  }

  @override
  Future<void> runJavaScript(String javaScript) {
    if (_disposed) return Future<void>.value();
    return _controller.runJavaScript(javaScript);
  }

  @override
  Widget buildView({
    required Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers,
  }) {
    return WebViewWidget(
      controller: _controller,
      gestureRecognizers: gestureRecognizers,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final channel = _channelName;
    if (channel != null) {
      unawaited(
        _controller.removeJavaScriptChannel(channel).catchError((_) {}),
      );
    }
    unawaited(
      _controller
          .setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: (_) => NavigationDecision.prevent,
            ),
          )
          .catchError((_) {}),
    );
  }
}

typedef GlobeViewControllerFactory = GlobeWebViewController Function();

/// Test hooks for deterministic 3D WebView widget & golden tests.
abstract final class GlobeViewTestHooks {
  @visibleForTesting
  static GlobeViewControllerFactory? controllerFactoryOverride;

  @visibleForTesting
  static GlobeConnectivityCheck? isOnlineOverride;

  @visibleForTesting
  static GlobeExternalUrlLauncher? externalUrlLauncherOverride;
}

/// Embedded Cesium 3D globe view communicating with `/embed/3d?ui=mobile&v=1`
/// over the protocol v1 `FvBridge` channel.
///
/// Created ONLY while 3D mode is active and disposed immediately on switching
/// back to 2D or leaving the screen. Receives no secrets, cookies, or tokens.
class GlobeView extends StatefulWidget {
  const GlobeView({
    super.key,
    required this.embedUri,
    required this.lang,
    required this.flights,
    required this.hasOwnAircraft,
    required this.paused,
    required this.onFallback,
    this.ownFlightId,
    this.controllerFactory,
    this.externalUrlLauncher,
    this.readyTimeout = globeBridgeReadyTimeout,
    this.throttleInterval = globeBridgeThrottleInterval,
    this.clock,
  });

  final Uri embedUri;
  final String lang;
  final String? ownFlightId;
  final List<GlobeBridgeFlight> flights;
  final bool hasOwnAircraft;
  final bool paused;
  final ValueChanged<GlobeFallbackReason> onFallback;
  final GlobeViewControllerFactory? controllerFactory;
  final GlobeExternalUrlLauncher? externalUrlLauncher;
  final Duration readyTimeout;
  final Duration throttleInterval;
  final DateTime Function()? clock;

  @override
  State<GlobeView> createState() => _GlobeViewState();
}

class _GlobeViewState extends State<GlobeView> {
  static const Color _globeBgColor = Color(0xFF07090D);

  late final GlobeWebViewController _controller;
  late final GlobeBridgeThrottler _throttler;
  final GlobeFlightSyncTracker _syncTracker = GlobeFlightSyncTracker();

  Timer? _readyTimer;
  bool _ready = false;
  bool _followOn = false;
  bool _fellBack = false;
  bool _disposed = false;

  late final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers = {
    Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
  };

  @override
  void initState() {
    super.initState();
    _throttler = GlobeBridgeThrottler(
      minInterval: widget.throttleInterval,
      clock: widget.clock,
    );
    final factory = widget.controllerFactory ??
        GlobeViewTestHooks.controllerFactoryOverride ??
        () => WebViewFlutterGlobeController();
    _controller = factory();
    unawaited(_configureAndLoad());
  }

  Future<void> _configureAndLoad() async {
    _readyTimer = Timer(widget.readyTimeout, () {
      if (!_ready && !_disposed) {
        _triggerFallback(GlobeFallbackReason.readyTimeout);
      }
    });

    try {
      await _controller.setBackgroundColor(_globeBgColor);
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.addJavaScriptChannel(
        globeBridgeChannelName,
        onMessageReceived: _onBridgeMessage,
      );
      await _controller.setNavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onWebResourceError: _onWebResourceError,
        onHttpError: _onHttpError,
      );
      if (_disposed) return;
      await _controller.loadRequest(widget.embedUri);
    } catch (_) {
      _triggerFallback(GlobeFallbackReason.loadFailed);
    }
  }

  @override
  void didUpdateWidget(covariant GlobeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready || _disposed) return;

    if (oldWidget.lang != widget.lang ||
        oldWidget.ownFlightId != widget.ownFlightId) {
      _sendInit();
    }
    if (oldWidget.paused != widget.paused) {
      _sendLifecyclePause(widget.paused);
    }
    if (oldWidget.hasOwnAircraft && !widget.hasOwnAircraft && _followOn) {
      setState(() => _followOn = false);
    }
    _scheduleFlightsSync();
  }

  @override
  void dispose() {
    _disposed = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    _throttler.dispose();
    _controller.dispose();
    super.dispose();
  }

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final target = Uri.tryParse(request.url);
    final action = decideGlobeNavigation(
      target,
      widget.embedUri,
      isMainFrame: request.isMainFrame,
    );
    switch (action) {
      case GlobeNavigationAction.allow:
        return NavigationDecision.navigate;
      case GlobeNavigationAction.prevent:
        return NavigationDecision.prevent;
      case GlobeNavigationAction.preventAndOpenExternal:
        if (target != null) {
          unawaited(_openExternalHttpsLink(target));
        }
        return NavigationDecision.prevent;
    }
  }

  Future<void> _openExternalHttpsLink(Uri uri) async {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      final launcher = widget.externalUrlLauncher ??
          GlobeViewTestHooks.externalUrlLauncherOverride;
      if (launcher != null) {
        await launcher(uri);
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // Ignore if no external browser handler is available.
    }
  }

  void _onWebResourceError(WebResourceError error) {
    // Only fail over on main-frame document load failures; ignore transient
    // subresource errors (e.g. individual map tiles).
    if (error.isForMainFrame == false) return;
    _triggerFallback(GlobeFallbackReason.loadFailed);
  }

  void _onHttpError(HttpResponseError error) {
    final status = error.response?.statusCode ?? 0;
    if (status < 400) return;
    if (!isMainFrameGlobeHttpError(error.request?.uri, widget.embedUri)) {
      return;
    }
    _triggerFallback(GlobeFallbackReason.loadFailed);
  }

  void _onBridgeMessage(String raw) {
    if (_disposed || _fellBack) return;
    final event = parseGlobeInboundMessage(raw);
    if (event == null) return;

    switch (event) {
      case GlobeReadyEvent():
        if (event.protocol != globeBridgeProtocolVersion) {
          _triggerFallback(GlobeFallbackReason.protocolMismatch);
          return;
        }
        if (_ready) return;
        _readyTimer?.cancel();
        _readyTimer = null;
        if (mounted) {
          setState(() => _ready = true);
        } else {
          _ready = true;
        }
        _sendInit();
        _syncTracker.reset();
        _scheduleFlightsSync();
        if (_followOn && widget.hasOwnAircraft) {
          _sendPayload(
            'follow',
            () => GlobeBridgeEncoder.follow(on: true),
          );
        }
        if (widget.paused) {
          _sendLifecyclePause(true);
        }
        return;

      case GlobeFollowChangedEvent():
        if (_followOn != event.on && mounted) {
          setState(() => _followOn = event.on);
        } else {
          _followOn = event.on;
        }
        return;

      case GlobeErrorEvent():
        if (event.code == 'webgl_unavailable') {
          _triggerFallback(GlobeFallbackReason.webglUnavailable);
        } else if (event.code == 'unsupported_protocol') {
          _triggerFallback(GlobeFallbackReason.protocolMismatch);
        } else {
          _triggerFallback(GlobeFallbackReason.bridgeError);
        }
        return;

      case GlobePerfEvent():
        if (kDebugMode) {
          debugPrint('GlobeView perf quality=${event.quality}');
        }
        return;
    }
  }

  void _triggerFallback(GlobeFallbackReason reason) {
    if (_fellBack || _disposed) return;
    _fellBack = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    if (mounted) {
      widget.onFallback(reason);
    }
  }

  void _sendPayload(String kind, Map<String, dynamic> Function() buildPayload) {
    if (_disposed || _fellBack || !_ready) return;
    _throttler.schedule(kind, () {
      if (_disposed || _fellBack || !_ready) return;
      final payload = buildPayload();
      final js = GlobeBridgeEncoder.toReceiveJavaScript(payload);
      unawaited(_controller.runJavaScript(js).catchError((_) {}));
    });
  }

  void _sendInit() {
    _sendPayload(
      'init',
      () => GlobeBridgeEncoder.init(
        lang: widget.lang,
        ownFlightId: widget.ownFlightId,
      ),
    );
  }

  void _scheduleFlightsSync() {
    if (_disposed || _fellBack || !_ready) return;
    _throttler.schedule('flights', () {
      if (_disposed || _fellBack || !_ready) return;
      final msg = _syncTracker.buildNextMessage(widget.flights);
      if (msg == null) return;
      final js = GlobeBridgeEncoder.toReceiveJavaScript(msg);
      unawaited(_controller.runJavaScript(js).catchError((_) {}));
    });
  }

  void _sendLifecyclePause(bool pause) {
    final kind = pause ? 'pause' : 'resume';
    _sendPayload(
      kind,
      () => pause ? GlobeBridgeEncoder.pause() : GlobeBridgeEncoder.resume(),
    );
  }

  void _onTapFollow() {
    if (!widget.hasOwnAircraft) return;
    final next = !_followOn;
    setState(() => _followOn = next);
    _sendPayload(
      'follow',
      () => GlobeBridgeEncoder.follow(on: next),
    );
  }

  void _onTapRecenter() {
    _sendPayload('recenter', GlobeBridgeEncoder.recenter);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);

    return Stack(
      key: FlightVisTestKeys.mapGlobeView,
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: _globeBgColor,
          child: _controller.buildView(
            gestureRecognizers: _gestureRecognizers,
          ),
        ),
        if (!_ready)
          IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xD60A0E14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        l10n.map3dLoading,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: 8,
          right: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.hasOwnAircraft) ...[
                _GlobeOverlayButton(
                  key: FlightVisTestKeys.map3dFollow,
                  icon: _followOn ? Icons.my_location : Icons.gps_fixed,
                  label: l10n.map3dFollowOwn,
                  active: _followOn,
                  onPressed: _onTapFollow,
                ),
                const SizedBox(height: 6),
              ],
              _GlobeOverlayButton(
                key: FlightVisTestKeys.map3dRecenter,
                icon: Icons.center_focus_strong,
                label: l10n.map3dRecenter,
                active: false,
                onPressed: _onTapRecenter,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlobeOverlayButton extends StatelessWidget {
  const _GlobeOverlayButton({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = active ? scheme.primary : scheme.surface.withValues(alpha: 0.94);
    final fg = active ? scheme.onPrimary : scheme.onSurface;
    return Semantics(
      button: true,
      toggled: active,
      label: label,
      child: Material(
        color: bg,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: active ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
