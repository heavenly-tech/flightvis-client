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
import '../map/map_tile_config.dart';
import '../map/own_trail_buffer.dart';
import '../map/trail_styles.dart';
import '../services/local_fix_source.dart';
import '../storage/preferences_store.dart';

/// Default map center (Tobalaba aerodrome, SCTB) before first GPS fix arrives.
const LatLng _defaultMapCenter = LatLng(-33.4569, -70.5478);

/// In-app live flight map shown on [TrackingScreen].
///
/// Renders:
/// - The pilot's own live position & locally buffered trail (windowed by the
///   effective trail setting `X`, with zero server round-trips).
/// - Club and public aircraft trails polled from `GET /api/me/live-trails`
///   every 5 seconds while foregrounded, honouring weak ETags (`304`) and the
///   persisted layer toggles (`Mío`, `Club`, `Público`).
class TrackingMapCard extends StatefulWidget {
  const TrackingMapCard({
    super.key,
    required this.client,
    required this.prefs,
    required this.ownTail,
    required this.trailMinutesOverride,
    required this.clubDefaultMinutes,
    required this.fixSource,
    this.mapHeight = 230,
    this.tileProvider,
    this.pollInterval = const Duration(seconds: 5),
    this.redrawThrottle = const Duration(seconds: 1),
    this.enablePolling,
    this.initialOwnFixes = const [],
    this.initialRemoteFlights = const [],
    this.onMapPointerActiveChanged,
    this.clock,
  });

  final FlightVisClient client;
  final PreferencesStore prefs;
  final String ownTail;
  final int? trailMinutesOverride;
  final int? clubDefaultMinutes;
  final LocalFixSource fixSource;
  final double mapHeight;
  final TileProvider? tileProvider;
  final Duration pollInterval;
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

  late bool _showOwn;
  late bool _showClub;
  late bool _showPublic;
  bool _followOwn = true;
  bool _mapReady = false;
  bool _isForeground = true;
  bool _pollInFlight = false;

  List<LiveTrailFlight> _remoteFlights = const [];
  String? _lastEtag;
  String? _lastEtagLayers;

  StreamSubscription<LocalFix>? _fixSub;
  Timer? _remotePollTimer;
  Timer? _redrawThrottleTimer;
  DateTime? _lastRedrawAt;

  bool get _pollingEnabled => widget.enablePolling ?? !AppConfig.screenshotTest;

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;

    _showOwn = widget.prefs.mapLayerOwn();
    _showClub = widget.prefs.mapLayerClub();
    _showPublic = widget.prefs.mapLayerPublic();

    _ownBuffer.addAll(widget.initialOwnFixes);
    _remoteFlights = _filterRemoteFlights(widget.initialRemoteFlights);

    if (_isForeground) {
      _resumeForegroundActivity(triggerImmediatePoll: true);
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
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    _redrawThrottleTimer?.cancel();
    _redrawThrottleTimer = null;
    unawaited(_fixSub?.cancel());
    _fixSub = null;
  }

  void _resumeForegroundActivity({required bool triggerImmediatePoll}) {
    unawaited(_syncRecentOwnFixes());
    unawaited(_fixSub?.cancel());
    _fixSub = widget.fixSource.watchFixes().listen(_onOwnFix);
    _reconfigureRemotePolling(triggerImmediate: triggerImmediatePoll);
  }

  Future<void> _syncRecentOwnFixes() async {
    final recent = await widget.fixSource.getRecentFixes();
    if (!mounted || recent.isEmpty) return;
    final hadFix = _ownBuffer.latestFix != null;
    final changed = _ownBuffer.addAll(recent);
    if (!changed || !_isForeground) return;
    _applyOwnFixRedraw(_now(), snapZoom: !hadFix);
  }

  void _onOwnFix(LocalFix fix) {
    final hadFix = _ownBuffer.latestFix != null;
    final changed = _ownBuffer.add(fix);
    if (!changed || !_isForeground || !mounted) return;

    final now = _now();
    final last = _lastRedrawAt;
    if (!hadFix ||
        last == null ||
        now.difference(last) >= widget.redrawThrottle) {
      _redrawThrottleTimer?.cancel();
      _redrawThrottleTimer = null;
      _applyOwnFixRedraw(now, snapZoom: !hadFix);
      return;
    }

    _redrawThrottleTimer ??= Timer(
      widget.redrawThrottle - now.difference(last),
      () {
        _redrawThrottleTimer = null;
        if (!mounted || !_isForeground) return;
        _applyOwnFixRedraw(_now());
      },
    );
  }

  void _applyOwnFixRedraw(DateTime now, {bool snapZoom = false}) {
    _lastRedrawAt = now;
    setState(() {});
    final latest = _ownBuffer.latestFix;
    if (_followOwn && _mapReady && latest != null) {
      final zoom = snapZoom ? 13.0 : _mapController.camera.zoom;
      _mapController.move(latest.latLng, zoom);
    }
  }

  void _reconfigureRemotePolling({required bool triggerImmediate}) {
    _remotePollTimer?.cancel();
    _remotePollTimer = null;
    if (!_isForeground || !_pollingEnabled) return;
    if (!_showClub && !_showPublic) return;

    if (triggerImmediate) {
      unawaited(_pollRemoteTrails());
    }
    _remotePollTimer = Timer.periodic(
      widget.pollInterval,
      (_) => unawaited(_pollRemoteTrails()),
    );
  }

  List<LiveTrailFlight> _filterRemoteFlights(List<LiveTrailFlight> flights) {
    return flights
        .where((f) => f.isPublic ? _showPublic : _showClub)
        .toList(growable: false);
  }

  Future<void> _pollRemoteTrails() async {
    if (!mounted || !_isForeground || !_pollingEnabled || _pollInFlight) return;
    final includeClub = _showClub;
    final includePublic = _showPublic;
    final requestedLayers = buildLiveTrailsLayersParam(
      includeClub: includeClub,
      includePublic: includePublic,
    );
    if (requestedLayers == null) return;

    final etagToSend =
        _lastEtagLayers == requestedLayers ? _lastEtag : null;
    _pollInFlight = true;
    try {
      final response = await widget.client.fetchLiveTrails(
        includeClub: includeClub,
        includePublic: includePublic,
        ifNoneMatch: etagToSend,
      );
      if (!mounted) return;
      final currentLayers = buildLiveTrailsLayersParam(
        includeClub: _showClub,
        includePublic: _showPublic,
      );
      if (currentLayers != requestedLayers) {
        // User toggled layers while request was in flight; discard stale result.
        return;
      }
      if (response.etag != null) {
        _lastEtag = response.etag;
        _lastEtagLayers = requestedLayers;
      }
      if (!response.notModified) {
        setState(() {
          _remoteFlights = _filterRemoteFlights(response.flights);
        });
      }
    } catch (_) {
      // Keep the last received data and stay silent on transient poll errors.
    } finally {
      _pollInFlight = false;
    }
  }

  void _toggleOwn(bool selected) {
    if (selected == _showOwn) return;
    setState(() => _showOwn = selected);
    unawaited(widget.prefs.setMapLayerOwn(selected));
  }

  void _toggleClub(bool selected) {
    if (selected == _showClub) return;
    setState(() {
      _showClub = selected;
      _lastEtag = null;
      _lastEtagLayers = null;
      _remoteFlights = (!_showClub && !_showPublic)
          ? const []
          : _filterRemoteFlights(_remoteFlights);
    });
    unawaited(widget.prefs.setMapLayerClub(selected));
    _reconfigureRemotePolling(triggerImmediate: true);
  }

  void _togglePublic(bool selected) {
    if (selected == _showPublic) return;
    setState(() {
      _showPublic = selected;
      _lastEtag = null;
      _lastEtagLayers = null;
      _remoteFlights = (!_showClub && !_showPublic)
          ? const []
          : _filterRemoteFlights(_remoteFlights);
    });
    unawaited(widget.prefs.setMapLayerPublic(selected));
    _reconfigureRemotePolling(triggerImmediate: true);
  }

  void _onRecenterTap() {
    setState(() => _followOwn = true);
    if (!_mapReady) return;
    final target = _ownBuffer.latestFix?.latLng ?? _firstRemoteLatLng();
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
    final own = _ownBuffer.latestFix;
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
    final own = _ownBuffer.latestFix;
    if (own != null) return own.latLng;
    final remote = _firstRemoteLatLng();
    if (remote != null) return remote;
    return _defaultMapCenter;
  }

  double _initialZoom() {
    if (_ownBuffer.latestFix != null || _firstRemoteLatLng() != null) {
      return 13.0;
    }
    return 11.0;
  }

  List<Polyline> _buildPolylines() {
    final polylines = <Polyline>[];

    // 1. Public trails (bottom-most: thinner, dashed, slate-purple).
    if (_showPublic) {
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
    if (_showClub) {
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
    if (_showPublic) {
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
    if (_showClub) {
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

    // Own position marker (always shown when Mío is ON, even when trail = Off).
    final ownLatest = _ownBuffer.latestFix;
    if (_showOwn && ownLatest != null) {
      markers.add(
        Marker(
          point: ownLatest.latLng,
          width: 104,
          height: 48,
          alignment: Alignment.center,
          child: _AircraftMarker(
            tail: widget.ownTail,
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: l10n.pilotMapLayersLabel,
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _LayerChip(
                key: FlightVisTestKeys.mapLayerMine,
                label: l10n.pilotMapLayerMine,
                semanticLabel: l10n.pilotMapLayerSemantic(l10n.pilotMapLayerMine),
                dotColor: TrailPalette.ownColor,
                selected: _showOwn,
                onSelected: _toggleOwn,
              ),
              _LayerChip(
                key: FlightVisTestKeys.mapLayerClub,
                label: l10n.pilotMapLayerClub,
                semanticLabel: l10n.pilotMapLayerSemantic(l10n.pilotMapLayerClub),
                dotColor: TrailPalette.clubColor,
                selected: _showClub,
                onSelected: _toggleClub,
              ),
              _LayerChip(
                key: FlightVisTestKeys.mapLayerPublic,
                label: l10n.pilotMapLayerPublic,
                semanticLabel:
                    l10n.pilotMapLayerSemantic(l10n.pilotMapLayerPublic),
                dotColor: TrailPalette.publicColor,
                selected: _showPublic,
                onSelected: _togglePublic,
              ),
            ],
          ),
        ),
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
                    if (_ownBuffer.latestFix == null)
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
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
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
                color: selected ? dotColor : dotColor.withValues(alpha: 0.4),
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
