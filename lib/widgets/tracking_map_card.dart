import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/live_trails_source.dart';
import '../map/map_tile_config.dart';
import '../map/own_trail_buffer.dart';
import '../map/trail_styles.dart';
import '../services/device_location_provider.dart';
import '../services/local_fix_source.dart';
import '../storage/preferences_store.dart';

/// Default map center (Tobalaba aerodrome, SCTB) before first GPS fix arrives.
const LatLng _defaultMapCenter = LatLng(-33.4569, -70.5478);

/// In-app live flight map reused across:
/// - Active club tracking (`TrackingScreen`, authenticated Mío + Club + Público)
/// - Pre-tracking live map (`LiveMapScreen`, guest public-only or authenticated)
/// - Active local recording (`LocalFlightScreen`, live own trail + public/club)
/// - Static saved local flight viewer (`LocalFlightsListScreen`, own trail only)
class TrackingMapCard extends StatefulWidget {
  const TrackingMapCard({
    super.key,
    required this.client,
    required this.prefs,
    this.ownTail,
    this.trailMinutesOverride,
    this.clubDefaultMinutes,
    this.fixSource,
    this.trailsSource,
    this.deviceLocationProvider,
    this.onSessionExpired,
    this.showLayerControls = true,
    this.mapHeight = 230,
    this.tileProvider,
    this.pollInterval = const Duration(seconds: 5),
    this.deviceLocationPollInterval = const Duration(seconds: 30),
    this.redrawThrottle = const Duration(seconds: 1),
    this.enablePolling,
    this.initialOwnFixes = const [],
    this.initialRemoteFlights = const [],
    this.onMapPointerActiveChanged,
    this.clock,
  });

  final FlightVisClient client;
  final PreferencesStore prefs;
  final String? ownTail;
  final int? trailMinutesOverride;
  final int? clubDefaultMinutes;
  final LocalFixSource? fixSource;

  /// Remote trails strategy. Defaults to [AuthenticatedLiveTrailsSource].
  final LiveTrailsSource? trailsSource;

  /// Last-known device location provider used when no live local fix exists.
  final DeviceLocationProvider? deviceLocationProvider;

  /// Invoked when the user taps "Iniciar sesión" on the inline 401 prompt.
  final VoidCallback? onSessionExpired;

  /// Whether to show layer filter chips and radius controls.
  final bool showLayerControls;

  final double mapHeight;
  final TileProvider? tileProvider;
  final Duration pollInterval;
  final Duration deviceLocationPollInterval;
  final Duration redrawThrottle;

  /// Defaults to `!AppConfig.screenshotTest`.
  final bool? enablePolling;

  /// Optional seed fixes for deterministic tests / screenshots.
  final List<LocalFix> initialOwnFixes;

  /// Optional seed remote flights for deterministic tests / screenshots.
  final List<LiveTrailFlight> initialRemoteFlights;

  /// Notifies enclosing scroll views while a finger is interacting with the map.
  final ValueChanged<bool>? onMapPointerActiveChanged;

  /// Optional injectable clock for deterministic throttling tests.
  final DateTime Function()? clock;

  @override
  State<TrackingMapCard> createState() => _TrackingMapCardState();
}

class _TrackingMapCardState extends State<TrackingMapCard>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  final OwnTrailBuffer _ownBuffer = OwnTrailBuffer();

  late LiveTrailsSource _trailsSource;
  late DeviceLocationProvider _deviceLocationProvider;

  late bool _showOwn;
  late bool _showClub;
  late bool _showPublic;
  late int _publicRadiusKm;
  bool _followOwn = true;
  bool _mapReady = false;
  bool _isForeground = true;
  bool _pollInFlight = false;
  bool _pollQueued = false;
  int _pollConfigSeq = 0;

  LocalFix? _deviceLocation;
  List<LiveTrailFlight> _remoteFlights = const [];
  String? _lastEtag;
  String? _lastEtagCacheKey;
  bool _sessionExpired = false;
  bool _pollStatusError = false;

  StreamSubscription<LocalFix>? _fixSub;
  Timer? _remotePollTimer;
  Timer? _rateLimitBackoffTimer;
  Timer? _deviceLocationTimer;
  Timer? _redrawThrottleTimer;
  DateTime? _lastRedrawAt;

  bool get _pollingEnabled =>
      _trailsSource.supportsRemotePolling &&
      (widget.enablePolling ?? !AppConfig.screenshotTest);

  LocalFix? get _effectivePosition => _ownBuffer.latestFix ?? _deviceLocation;

  bool get _effectiveShowClub => _trailsSource.supportsClubLayer && _showClub;

  bool get _effectiveShowPublic =>
      _trailsSource.supportsRemotePolling && _showPublic;

  bool get _hasPollableRemoteLayer =>
      _effectiveShowClub ||
      (_effectiveShowPublic && _effectivePosition != null);

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;

    _trailsSource =
        widget.trailsSource ?? AuthenticatedLiveTrailsSource(widget.client);
    _deviceLocationProvider =
        widget.deviceLocationProvider ?? const PlatformDeviceLocationProvider();

    _showOwn = widget.prefs.mapLayerOwn();
    if (_trailsSource.supportsClubLayer) {
      _showClub = widget.prefs.mapLayerClub();
      _showPublic = widget.prefs.mapLayerPublic();
    } else if (_trailsSource.supportsRemotePolling) {
      // Guest / public-only mode opens directly with Público ON and Club disabled.
      _showClub = false;
      _showPublic = true;
    } else {
      // Static saved local flight playback: own trail only.
      _showOwn = true;
      _showClub = false;
      _showPublic = false;
    }
    _publicRadiusKm = widget.prefs.mapPublicRadiusKm();

    _ownBuffer.addAll(widget.initialOwnFixes);
    _remoteFlights = _filterRemoteFlights(widget.initialRemoteFlights);

    if (_isForeground) {
      _resumeForegroundActivity(triggerImmediatePoll: true);
    }
  }

  @override
  void didUpdateWidget(covariant TrackingMapCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trailsSource != widget.trailsSource ||
        oldWidget.client != widget.client) {
      _trailsSource =
          widget.trailsSource ?? AuthenticatedLiveTrailsSource(widget.client);
      if (!_trailsSource.supportsClubLayer) {
        _showClub = false;
      }
      _invalidateEtag();
      if (_isForeground) {
        _reconfigureRemotePolling(triggerImmediate: true);
      }
    }
    if (oldWidget.deviceLocationProvider != widget.deviceLocationProvider) {
      _deviceLocationProvider = widget.deviceLocationProvider ??
          const PlatformDeviceLocationProvider();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pauseForegroundActivity();
    _mapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _isForeground) return;
    _isForeground = resumed;
    if (!resumed) {
      _pauseForegroundActivity();
    } else {
      _resumeForegroundActivity(triggerImmediatePoll: true);
    }
  }

  void _pauseForegroundActivity() {
    _pollConfigSeq++;
    _pollQueued = false;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _rateLimitBackoffTimer?.cancel();
    _rateLimitBackoffTimer = null;
    _deviceLocationTimer?.cancel();
    _deviceLocationTimer = null;
    _redrawThrottleTimer?.cancel();
    _redrawThrottleTimer = null;
    unawaited(_fixSub?.cancel());
    _fixSub = null;
  }

  void _resumeForegroundActivity({required bool triggerImmediatePoll}) {
    unawaited(_fixSub?.cancel());
    final fixSource = widget.fixSource;
    if (fixSource != null) {
      _fixSub = fixSource.watchFixes().listen(_onOwnFix);
    }
    if (!_trailsSource.supportsRemotePolling && fixSource == null) {
      return;
    }
    if (_effectiveShowPublic && triggerImmediatePoll) {
      unawaited(
        _syncPositionsAndStartPolling(
          triggerImmediatePoll: triggerImmediatePoll,
        ),
      );
    } else {
      unawaited(_syncRecentOwnFixes());
      unawaited(_refreshDeviceLocation(triggerPublicPollOnFirstPos: true));
      _reconfigureDeviceLocationPolling();
      _reconfigureRemotePolling(triggerImmediate: triggerImmediatePoll);
    }
  }

  Future<void> _syncPositionsAndStartPolling({
    required bool triggerImmediatePoll,
  }) async {
    final configSeq = _pollConfigSeq;
    await _syncRecentOwnFixes(triggerPublicPollOnFirstFix: false);
    if (!mounted || !_isForeground || configSeq != _pollConfigSeq) return;
    if (_ownBuffer.latestFix == null) {
      await _refreshDeviceLocation(triggerPublicPollOnFirstPos: false);
      if (!mounted || !_isForeground || configSeq != _pollConfigSeq) return;
    }
    _reconfigureDeviceLocationPolling();
    _reconfigureRemotePolling(triggerImmediate: triggerImmediatePoll);
  }

  void _reconfigureDeviceLocationPolling() {
    _deviceLocationTimer?.cancel();
    _deviceLocationTimer = null;
    if (!_isForeground || !_pollingEnabled) return;
    if (_ownBuffer.latestFix != null) return;
    _deviceLocationTimer = Timer.periodic(
      widget.deviceLocationPollInterval,
      (_) => unawaited(_refreshDeviceLocation(triggerPublicPollOnFirstPos: true)),
    );
  }

  Future<void> _refreshDeviceLocation({
    required bool triggerPublicPollOnFirstPos,
  }) async {
    if (!mounted || !_isForeground) return;
    if (_ownBuffer.latestFix != null) return;
    final hadPos = _effectivePosition != null;
    final loc = await _deviceLocationProvider.getLastKnownLocation();
    if (!mounted || !_isForeground || loc == null || !loc.hasValidCoordinates) {
      return;
    }
    if (_ownBuffer.latestFix != null) return;
    final prev = _deviceLocation;
    final changed = prev == null ||
        prev.latitude != loc.latitude ||
        prev.longitude != loc.longitude ||
        prev.timeMs != loc.timeMs;
    if (!changed) return;
    setState(() => _deviceLocation = loc);
    if (_followOwn && _mapReady) {
      final zoom = hadPos ? _mapController.camera.zoom : 13.0;
      _mapController.move(loc.latLng, zoom);
    }
    if (!hadPos && _effectiveShowPublic && triggerPublicPollOnFirstPos) {
      _invalidateEtag();
      _reconfigureRemotePolling(triggerImmediate: true);
    }
  }

  Future<void> _syncRecentOwnFixes({
    bool triggerPublicPollOnFirstFix = true,
  }) async {
    final fixSource = widget.fixSource;
    if (fixSource == null) return;
    final recent = await fixSource.getRecentFixes();
    if (!mounted || recent.isEmpty) return;
    final hadPos = _effectivePosition != null;
    final changed = _ownBuffer.addAll(recent);
    if (!changed || !_isForeground) return;
    _deviceLocationTimer?.cancel();
    _deviceLocationTimer = null;
    _applyOwnFixRedraw(_now(), snapZoom: !hadPos);
    if (!hadPos && _effectiveShowPublic && triggerPublicPollOnFirstFix) {
      _invalidateEtag();
      _reconfigureRemotePolling(triggerImmediate: true);
    }
  }

  void _onOwnFix(LocalFix fix) {
    final hadPos = _effectivePosition != null;
    final changed = _ownBuffer.add(fix);
    if (!changed || !_isForeground || !mounted) return;
    _deviceLocationTimer?.cancel();
    _deviceLocationTimer = null;

    final now = _now();
    final last = _lastRedrawAt;
    if (!hadPos ||
        last == null ||
        now.difference(last) >= widget.redrawThrottle) {
      _redrawThrottleTimer?.cancel();
      _redrawThrottleTimer = null;
      _applyOwnFixRedraw(now, snapZoom: !hadPos);
    } else {
      _redrawThrottleTimer ??= Timer(
        widget.redrawThrottle - now.difference(last),
        () {
          _redrawThrottleTimer = null;
          if (!mounted || !_isForeground) return;
          _applyOwnFixRedraw(_now());
        },
      );
    }

    if (!hadPos && _effectiveShowPublic) {
      _invalidateEtag();
      _reconfigureRemotePolling(triggerImmediate: true);
    }
  }

  void _applyOwnFixRedraw(DateTime now, {bool snapZoom = false}) {
    _lastRedrawAt = now;
    setState(() {});
    final latest = _effectivePosition;
    if (_followOwn && _mapReady && latest != null) {
      final zoom = snapZoom ? 13.0 : _mapController.camera.zoom;
      _mapController.move(latest.latLng, zoom);
    }
  }

  void _invalidateEtag() {
    _lastEtag = null;
    _lastEtagCacheKey = null;
  }

  String? _etagCacheKey({
    required bool includeClub,
    required bool includePublic,
    required int radiusKm,
    int? minAglFt,
  }) {
    final layers = buildLiveTrailsLayersParam(
      includeClub: includeClub,
      includePublic: includePublic,
    );
    if (layers == null) return null;
    if (!includePublic) return layers;
    final aglSuffix =
        minAglFt != null ? '|agl=${minAglFt.clamp(0, 20000)}' : '';
    return '$layers|r=$radiusKm$aglSuffix';
  }

  void _scheduleAnonymousRateLimitBackoff(int? retryAfterSeconds) {
    final raw = retryAfterSeconds ?? widget.pollInterval.inSeconds;
    final seconds = raw.clamp(1, 60);
    _pollQueued = false;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _rateLimitBackoffTimer?.cancel();
    final seq = _pollConfigSeq;
    _rateLimitBackoffTimer = Timer(Duration(seconds: seconds), () {
      _rateLimitBackoffTimer = null;
      if (!mounted || !_isForeground || !_pollingEnabled || seq != _pollConfigSeq) {
        return;
      }
      _reconfigureRemotePolling(triggerImmediate: true);
    });
  }

  void _reconfigureRemotePolling({required bool triggerImmediate}) {
    _pollConfigSeq++;
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _rateLimitBackoffTimer?.cancel();
    _rateLimitBackoffTimer = null;
    if (!_isForeground || !_pollingEnabled) return;
    if (!_hasPollableRemoteLayer) {
      _pollQueued = false;
      return;
    }

    if (triggerImmediate) {
      unawaited(_pollRemoteTrails(forceImmediate: true));
    }
    _remotePollTimer = Timer.periodic(
      widget.pollInterval,
      (_) => unawaited(_pollRemoteTrails()),
    );
  }

  List<LiveTrailFlight> _filterRemoteFlights(List<LiveTrailFlight> flights) {
    return flights
        .where((f) => f.isPublic ? _effectiveShowPublic : _effectiveShowClub)
        .toList(growable: false);
  }

  Future<void> _pollRemoteTrails({bool forceImmediate = false}) async {
    if (!mounted || !_isForeground || !_pollingEnabled) return;
    final includeClub = _effectiveShowClub;
    final pos = _effectivePosition;
    final includePublic = _effectiveShowPublic && pos != null;
    final requestedRadiusKm = _publicRadiusKm;
    final requestedCacheKey = _etagCacheKey(
      includeClub: includeClub,
      includePublic: includePublic,
      radiusKm: requestedRadiusKm,
    );
    if (requestedCacheKey == null) {
      _pollQueued = false;
      return;
    }
    if (_pollInFlight) {
      if (forceImmediate) _pollQueued = true;
      return;
    }

    final etagToSend =
        _lastEtagCacheKey == requestedCacheKey ? _lastEtag : null;
    _pollInFlight = true;
    try {
      final response = await _trailsSource.fetch(
        includeClub: includeClub,
        includePublic: includePublic,
        lat: includePublic ? pos.latitude : null,
        lon: includePublic ? pos.longitude : null,
        radiusKm: includePublic ? requestedRadiusKm : null,
        ifNoneMatch: etagToSend,
      );
      if (!mounted) return;
      final currentCacheKey = _etagCacheKey(
        includeClub: _effectiveShowClub,
        includePublic: _effectiveShowPublic && _effectivePosition != null,
        radiusKm: _publicRadiusKm,
      );
      if (currentCacheKey != requestedCacheKey) {
        return;
      }
      if (response.etag != null) {
        _lastEtag = response.etag;
        _lastEtagCacheKey = requestedCacheKey;
      }
      final hadError = _sessionExpired || _pollStatusError;
      if (!response.notModified || hadError) {
        setState(() {
          _sessionExpired = false;
          _pollStatusError = false;
          if (!response.notModified) {
            _remoteFlights = _filterRemoteFlights(response.flights);
          }
        });
      }
    } on FlightVisException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401 && _trailsSource.supportsAuthExpiry) {
        if (!_sessionExpired || _pollStatusError) {
          setState(() {
            _sessionExpired = true;
            _pollStatusError = false;
          });
        }
      } else if (e.statusCode == 429 && !_trailsSource.supportsAuthExpiry) {
        // Anonymous endpoint rate limit: back off silently to Retry-After (cap 60s).
        _scheduleAnonymousRateLimitBackoff(e.retryAfterSeconds);
      } else {
        // Keep last received data and show subtle status line without SnackBar spam.
        if (!_pollStatusError) {
          setState(() => _pollStatusError = true);
        }
      }
    } catch (_) {
      if (!mounted) return;
      if (!_pollStatusError) {
        setState(() => _pollStatusError = true);
      }
    } finally {
      _pollInFlight = false;
      if (_pollQueued && mounted && _isForeground && _pollingEnabled) {
        _pollQueued = false;
        unawaited(_pollRemoteTrails());
      }
    }
  }

  void _toggleOwn(bool selected) {
    if (selected == _showOwn) return;
    setState(() => _showOwn = selected);
    unawaited(widget.prefs.setMapLayerOwn(selected));
  }

  void _toggleClub(bool selected) {
    if (!_trailsSource.supportsClubLayer) return;
    if (selected == _showClub) return;
    setState(() {
      _showClub = selected;
      _invalidateEtag();
      _remoteFlights = (!_effectiveShowClub && !_effectiveShowPublic)
          ? const []
          : _filterRemoteFlights(_remoteFlights);
    });
    unawaited(widget.prefs.setMapLayerClub(selected));
    _reconfigureRemotePolling(triggerImmediate: true);
  }

  void _togglePublic(bool selected) {
    if (!_trailsSource.supportsRemotePolling) return;
    if (selected == _showPublic) return;
    setState(() {
      _showPublic = selected;
      _invalidateEtag();
      _remoteFlights = (!_effectiveShowClub && !_effectiveShowPublic)
          ? const []
          : _filterRemoteFlights(_remoteFlights);
    });
    if (_trailsSource.supportsClubLayer) {
      unawaited(widget.prefs.setMapLayerPublic(selected));
    }
    _reconfigureRemotePolling(triggerImmediate: true);
  }

  void _changePublicRadius(int radiusKm) {
    final normalized = PreferencesStore.normalizePublicRadiusKm(radiusKm);
    if (normalized == _publicRadiusKm) return;
    setState(() {
      _publicRadiusKm = normalized;
      _invalidateEtag();
    });
    unawaited(widget.prefs.setMapPublicRadiusKm(normalized));
    if (_effectiveShowPublic && _effectivePosition != null) {
      _reconfigureRemotePolling(triggerImmediate: true);
    }
  }

  void _onRecenterTap() {
    setState(() => _followOwn = true);
    if (!_mapReady) return;
    final target = _effectivePosition?.latLng ?? _firstRemoteLatLng();
    if (target != null) {
      _mapController.move(target, _mapController.camera.zoom);
    }
  }

  void _zoomBy(double delta) {
    if (!_mapReady) return;
    final nextZoom = (_mapController.camera.zoom + delta).clamp(
      kOsmTileConfig.minZoom,
      kOsmTileConfig.maxZoom,
    );
    final own = _effectivePosition;
    final center =
        (_followOwn && own != null) ? own.latLng : _mapController.camera.center;
    _mapController.move(center, nextZoom);
  }

  LatLng? _firstRemoteLatLng() {
    for (final f in _remoteFlights) {
      final p = f.latestPoint;
      if (p != null) return LatLng(p.latitude, p.longitude);
    }
    return null;
  }

  LatLng _initialCenter() {
    final own = _effectivePosition;
    if (own != null) return own.latLng;
    final remote = _firstRemoteLatLng();
    if (remote != null) return remote;
    return _defaultMapCenter;
  }

  double _initialZoom() {
    if (_effectivePosition != null || _firstRemoteLatLng() != null) {
      return 13.0;
    }
    return 11.0;
  }

  List<Polyline> _buildPolylines() {
    final polylines = <Polyline>[];

    // 1. Public trails (bottom-most: thinner, dashed, slate-purple).
    if (_effectiveShowPublic) {
      for (final flight in _remoteFlights) {
        if (!flight.isPublic) continue;
        if (flight.trailMinutes == 0 || flight.points.length < 2) continue;
        polylines.addAll(
          buildFadedTrailPolylines(
            points: [
              for (final p in flight.points) LatLng(p.latitude, p.longitude),
            ],
            timestampsMs: [for (final p in flight.points) p.timeMs],
            kind: MapTrailKind.public,
          ),
        );
      }
    }

    // 2. Club trails (middle: aviation blue, solid).
    if (_effectiveShowClub) {
      for (final flight in _remoteFlights) {
        if (flight.isPublic) continue;
        if (flight.trailMinutes == 0 || flight.points.length < 2) continue;
        polylines.addAll(
          buildFadedTrailPolylines(
            points: [
              for (final p in flight.points) LatLng(p.latitude, p.longitude),
            ],
            timestampsMs: [for (final p in flight.points) p.timeMs],
            kind: MapTrailKind.club,
          ),
        );
      }
    }

    // 3. Own trail (top-most: thick vivid orange-red with crisp white halo).
    if (_showOwn) {
      final ownWindowed = _ownBuffer.windowedTrail(
        overrideMinutes: widget.trailMinutesOverride,
        clubDefaultMinutes: widget.clubDefaultMinutes,
      );
      if (ownWindowed.length >= 2) {
        polylines.addAll(
          buildFadedTrailPolylines(
            points: [for (final f in ownWindowed) f.latLng],
            timestampsMs: [for (final f in ownWindowed) f.timeMs],
            kind: MapTrailKind.own,
          ),
        );
      }
    }

    return polylines;
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    // Public aircraft markers (bottom).
    if (_effectiveShowPublic) {
      for (final flight in _remoteFlights) {
        if (!flight.isPublic) continue;
        final latest = flight.latestPoint;
        if (latest == null) continue;
        markers.add(
          Marker(
            point: LatLng(latest.latitude, latest.longitude),
            width: 96,
            height: 44,
            alignment: Alignment.center,
            child: _AircraftMarker(
              tail: flight.tail,
              kind: MapTrailKind.public,
            ),
          ),
        );
      }
    }

    // Club aircraft markers (middle).
    if (_effectiveShowClub) {
      for (final flight in _remoteFlights) {
        if (flight.isPublic) continue;
        final latest = flight.latestPoint;
        if (latest == null) continue;
        markers.add(
          Marker(
            point: LatLng(latest.latitude, latest.longitude),
            width: 96,
            height: 44,
            alignment: Alignment.center,
            child: _AircraftMarker(
              tail: flight.tail,
              kind: MapTrailKind.club,
            ),
          ),
        );
      }
    }

    // Own position marker (from live local fix or device last-known location).
    final ownLatest = _effectivePosition;
    if (_showOwn && ownLatest != null) {
      markers.add(
        Marker(
          point: ownLatest.latLng,
          width: 104,
          height: 48,
          alignment: Alignment.center,
          child: _AircraftMarker(
            tail: widget.ownTail ?? '',
            kind: MapTrailKind.own,
            bearingDegrees: ownLatest.bearing,
          ),
        ),
      );
    }

    return markers;
  }

  Future<void> _openOsmAttribution() async {
    try {
      await launchUrl(
        Uri.parse(kOsmTileConfig.attributionUri),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Ignore if no external browser handler is available.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final resolvedTileProvider =
        widget.tileProvider ?? TrackingMapTestHooks.tileProviderOverride;
    final polylines = _buildPolylines();
    final markers = _buildMarkers();
    final isGuestMode =
        !_trailsSource.supportsClubLayer && _trailsSource.supportsRemotePolling;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showLayerControls) ...[
          Semantics(
            label: l10n.pilotMapLayersLabel,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _LayerChip(
                  key: FlightVisTestKeys.mapLayerMine,
                  label: l10n.pilotMapLayerMine,
                  semanticLabel:
                      l10n.pilotMapLayerSemantic(l10n.pilotMapLayerMine),
                  dotColor: TrailPalette.ownColor,
                  selected: _showOwn,
                  onSelected: _toggleOwn,
                ),
                if (_trailsSource.supportsRemotePolling)
                  _LayerChip(
                    key: FlightVisTestKeys.mapLayerClub,
                    label: l10n.pilotMapLayerClub,
                    semanticLabel:
                        l10n.pilotMapLayerSemantic(l10n.pilotMapLayerClub),
                    dotColor: TrailPalette.clubColor,
                    selected: _effectiveShowClub,
                    onSelected:
                        _trailsSource.supportsClubLayer ? _toggleClub : null,
                  ),
                if (_trailsSource.supportsRemotePolling)
                  _LayerChip(
                    key: FlightVisTestKeys.mapLayerPublic,
                    label: l10n.pilotMapLayerPublic,
                    semanticLabel:
                        l10n.pilotMapLayerSemantic(l10n.pilotMapLayerPublic),
                    dotColor: TrailPalette.publicColor,
                    selected: _effectiveShowPublic,
                    onSelected: _togglePublic,
                  ),
                if (_effectiveShowPublic)
                  _PublicRadiusMenu(
                    key: FlightVisTestKeys.mapPublicRadiusButton,
                    radiusKm: _publicRadiusKm,
                    label: l10n.pilotMapPublicRadius(_publicRadiusKm),
                    tooltip: l10n.pilotMapPublicRadiusTooltip,
                    semanticLabel:
                        l10n.pilotMapPublicRadiusSemantic(_publicRadiusKm),
                    optionLabel: l10n.pilotMapPublicRadiusKm,
                    onSelected: _changePublicRadius,
                  ),
              ],
            ),
          ),
          if (isGuestMode) ...[
            const SizedBox(height: 6),
            Text(
              l10n.mapClubRequiresSignIn,
              key: FlightVisTestKeys.mapClubDisabledHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
        if (_sessionExpired) ...[
          const SizedBox(height: 6),
          Card(
            key: FlightVisTestKeys.mapSessionExpiredBanner,
            margin: EdgeInsets.zero,
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_clock,
                    size: 16,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.sessionExpiredPrompt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  if (widget.onSessionExpired != null)
                    TextButton(
                      key: FlightVisTestKeys.mapSessionExpiredSignIn,
                      onPressed: widget.onSessionExpired,
                      child: Text(l10n.pilotSignInButton),
                    ),
                ],
              ),
            ),
          ),
        ] else if (_pollStatusError) ...[
          const SizedBox(height: 6),
          Row(
            key: FlightVisTestKeys.mapPollStatusError,
            children: [
              Icon(
                Icons.cloud_off,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.mapPollServerOffline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_effectiveShowPublic && _effectivePosition == null) ...[
          const SizedBox(height: 6),
          Row(
            key: FlightVisTestKeys.mapPublicWaitingPosition,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.location_searching,
                size: 14,
                color: TrailPalette.publicColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.pilotMapPublicWaitingPosition,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        SizedBox(
          key: FlightVisTestKeys.trackingMap,
          height: widget.mapHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TrailPalette.mapCanvasBackground,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Listener(
                onPointerDown: (_) =>
                    widget.onMapPointerActiveChanged?.call(true),
                onPointerUp: (_) =>
                    widget.onMapPointerActiveChanged?.call(false),
                onPointerCancel: (_) =>
                    widget.onMapPointerActiveChanged?.call(false),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _initialCenter(),
                        initialZoom: _initialZoom(),
                        minZoom: kOsmTileConfig.minZoom,
                        maxZoom: kOsmTileConfig.maxZoom,
                        backgroundColor: TrailPalette.mapCanvasBackground,
                        onMapReady: () => _mapReady = true,
                        onPositionChanged: (_, hasGesture) {
                          if (hasGesture && _followOwn) {
                            setState(() => _followOwn = false);
                          }
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: kOsmTileConfig.urlTemplate,
                          subdomains: const [],
                          userAgentPackageName:
                              kOsmTileConfig.userAgentPackageName,
                          maxZoom: kOsmTileConfig.maxZoom,
                          maxNativeZoom: kOsmTileConfig.maxNativeZoom,
                          panBuffer: 0,
                          keepBuffer: 1,
                          tileProvider: resolvedTileProvider,
                          tileDisplay: resolvedTileProvider != null
                              ? const TileDisplay.instantaneous()
                              : const TileDisplay.fadeIn(),
                        ),
                        if (polylines.isNotEmpty)
                          PolylineLayer(polylines: polylines),
                        if (markers.isNotEmpty) MarkerLayer(markers: markers),
                        MediaQuery.removePadding(
                          context: context,
                          removeTop: true,
                          removeBottom: true,
                          removeLeft: true,
                          removeRight: true,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.bottomRight,
                              child: DefaultTextStyle(
                                style: (theme.textTheme.labelSmall ??
                                        const TextStyle(fontSize: 10))
                                    .copyWith(
                                  fontSize: 10,
                                  color: theme.colorScheme.onSurface,
                                ),
                                child: SimpleAttributionWidget(
                                  key: FlightVisTestKeys.mapAttribution,
                                  backgroundColor: theme.colorScheme.surface
                                      .withValues(alpha: 0.85),
                                  source: Text(kOsmTileConfig.attributionSource),
                                  onTap: _openOsmAttribution,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_effectivePosition == null)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.gps_not_fixed,
                                  size: 14,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  l10n.pilotMapWaitingGps,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MapControlButton(
                            key: FlightVisTestKeys.mapFollowToggle,
                            icon: _followOwn
                                ? Icons.my_location
                                : Icons.location_searching,
                            tooltip: _followOwn
                                ? l10n.pilotMapFollowOn
                                : l10n.pilotMapRecenter,
                            active: _followOwn,
                            onPressed: _onRecenterTap,
                          ),
                          const SizedBox(height: 6),
                          _MapControlButton(
                            key: FlightVisTestKeys.mapZoomIn,
                            icon: Icons.add,
                            tooltip: l10n.pilotMapZoomIn,
                            onPressed: () => _zoomBy(1.0),
                          ),
                          const SizedBox(height: 4),
                          _MapControlButton(
                            key: FlightVisTestKeys.mapZoomOut,
                            icon: Icons.remove,
                            tooltip: l10n.pilotMapZoomOut,
                            onPressed: () => _zoomBy(-1.0),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LayerChip extends StatelessWidget {
  const _LayerChip({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.dotColor,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final String semanticLabel;
  final Color dotColor;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    final enabled = onSelected != null;
    return FilterChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      selectedColor: dotColor.withValues(alpha: 0.16),
      side: BorderSide(
        color: selected
            ? dotColor
            : Theme.of(context).colorScheme.outlineVariant,
      ),
      label: Semantics(
        label: semanticLabel,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: !enabled
                    ? Theme.of(context).disabledColor
                    : (selected ? dotColor : dotColor.withValues(alpha: 0.4)),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _PublicRadiusMenu extends StatelessWidget {
  const _PublicRadiusMenu({
    super.key,
    required this.radiusKm,
    required this.label,
    required this.tooltip,
    required this.semanticLabel,
    required this.optionLabel,
    required this.onSelected,
  });

  final int radiusKm;
  final String label;
  final String tooltip;
  final String semanticLabel;
  final String Function(int km) optionLabel;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<int>(
      initialValue: radiusKm,
      tooltip: tooltip,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final km in PreferencesStore.publicRadiusKmOptions)
          CheckedPopupMenuItem<int>(
            key: FlightVisTestKeys.mapPublicRadiusOption(km),
            value: km,
            checked: km == radiusKm,
            child: Text(optionLabel(km)),
          ),
      ],
      child: Semantics(
        button: true,
        label: semanticLabel,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: TrailPalette.publicColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TrailPalette.publicColor),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: TrailPalette.publicColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = active ? scheme.primary : scheme.surface.withValues(alpha: 0.94);
    final fg = active ? scheme.onPrimary : scheme.onSurface;
    return Material(
      color: bg,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: fg),
          ),
        ),
      ),
    );
  }
}

class _AircraftMarker extends StatelessWidget {
  const _AircraftMarker({
    required this.tail,
    required this.kind,
    this.bearingDegrees,
  });

  final String tail;
  final MapTrailKind kind;
  final double? bearingDegrees;

  @override
  Widget build(BuildContext context) {
    final isOwn = kind == MapTrailKind.own;
    final isPublic = kind == MapTrailKind.public;
    final dotColor = switch (kind) {
      MapTrailKind.own => TrailPalette.ownColor,
      MapTrailKind.club => TrailPalette.clubColor,
      MapTrailKind.public => TrailPalette.publicColor,
    };
    final badgeBg = switch (kind) {
      MapTrailKind.own => TrailPalette.ownBadgeBackground,
      MapTrailKind.club => TrailPalette.clubBadgeBackground,
      MapTrailKind.public => TrailPalette.publicBadgeBackground,
    };
    final badgeFg = isOwn ? Colors.white : dotColor;

    final dotSize = isOwn ? 18.0 : (isPublic ? 12.0 : 14.0);
    final markerDot = Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white,
          width: isOwn ? 2.5 : 2.0,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: isOwn && bearingDegrees != null
          ? Transform.rotate(
              angle: bearingDegrees! * math.pi / 180.0,
              child: const Icon(
                Icons.navigation,
                size: 11,
                color: Colors.white,
              ),
            )
          : null,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        markerDot,
        const SizedBox(height: 2),
        if (tail.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: badgeBg.withValues(alpha: isOwn ? 0.96 : 0.92),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isOwn ? Colors.white : dotColor,
                width: isOwn ? 1.2 : 1.0,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              tail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isOwn ? 10.5 : 9.5,
                fontWeight: FontWeight.w700,
                color: badgeFg,
                height: 1.1,
              ),
            ),
          ),
      ],
    );
  }
}
