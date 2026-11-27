import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../ci_test_keys.dart';
import '../l10n/api_errors.dart';
import '../l10n/pilot_l10n.dart';
import '../map/own_trail_buffer.dart';
import '../services/app_repository.dart';
import '../services/device_location_provider.dart';
import '../services/local_fix_source.dart';
import '../services/tracking_lifecycle.dart';
import '../services/tracking_service.dart';
import '../widgets/tracking_map_card.dart';
import '../widgets/trail_length_chips.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({
    super.key,
    required this.repo,
    required this.flightId,
    required this.tail,
    required this.tracking,
    required this.onStopped,
    this.onSessionExpired,
    this.deviceLocationProvider,
    this.tileProvider,
    this.fixSource,
    this.enableMapPolling,
    this.mapPollInterval = const Duration(seconds: 5),
    this.initialOwnFixes = const [],
    this.initialRemoteFlights = const [],
  });

  final AppRepository repo;
  final String flightId;
  final String tail;
  final TrackingService tracking;
  final VoidCallback onStopped;
  final VoidCallback? onSessionExpired;
  final DeviceLocationProvider? deviceLocationProvider;
  final TileProvider? tileProvider;
  final LocalFixSource? fixSource;
  final bool? enableMapPolling;
  final Duration mapPollInterval;
  final List<LocalFix> initialOwnFixes;
  final List<LiveTrailFlight> initialRemoteFlights;

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with WidgetsBindingObserver {
  bool _active = false;
  String? _error;
  String? _missingTokenMessage;
  Timer? _poll;
  int? _trailMinutes;
  int? _confirmedTrailMinutes;
  int _trailRequestSeq = 0;
  bool _mapPointerActive = false;

  int? get _clubTrailMinutesDefault =>
      widget.repo.client.clubTrailMinutesDefault ??
      widget.repo.prefs.clubTrailMinutesDefault();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _missingTokenMessage = context.pilotL10n.pilotDeviceTokenMissing;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trailMinutes = widget.repo.prefs.activeFlightTrailMinutes();
    _confirmedTrailMinutes = _trailMinutes;
    _bootstrap();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _startStatusPoll();
    }
  }

  void _startStatusPoll() {
    if (AppConfig.screenshotTest) return;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_tick());
      _startStatusPoll();
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _onSelectTrail(int? minutes) async {
    if (minutes == _trailMinutes) return;
    final seq = ++_trailRequestSeq;
    setState(() => _trailMinutes = minutes);
    try {
      final confirmed = await widget.repo.client.setFlightTrail(
        widget.flightId,
        minutes,
      );
      if (!mounted || seq != _trailRequestSeq) return;
      _confirmedTrailMinutes = confirmed;
      if (_trailMinutes != confirmed) {
        setState(() => _trailMinutes = confirmed);
      }
      await widget.repo.prefs.setActiveFlightTrailMinutes(confirmed);
    } catch (_) {
      if (!mounted || seq != _trailRequestSeq) return;
      setState(() => _trailMinutes = _confirmedTrailMinutes);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.pilotL10n.pilotTrailUpdateFailed)),
        );
    }
  }

  Future<void> _haltTracking() async {
    await widget.tracking.stop();
    await widget.repo.prefs.setActiveFlightId(null);
    if (mounted) widget.onStopped();
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (checkinExpired(
      expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: nowMs,
    )) {
      await _haltTracking();
      return;
    }
    if (await widget.tracking.ingestFailureRequiresStop()) {
      await _haltTracking();
      return;
    }
    final on = await widget.tracking.isTracking();
    if (mounted) setState(() => _active = on);
  }

  Future<void> _bootstrap() async {
    final expiresMs = widget.repo.prefs.checkinExpiresAtMs();
    if (checkinExpired(expiresAtMs: expiresMs, nowMs: DateTime.now().millisecondsSinceEpoch)) {
      await _haltTracking();
      return;
    }
    final token = (await widget.repo.secure.readDeviceToken())?.trim();
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _error = _missingTokenMessage);
      return;
    }
    await widget.tracking.initForFlight(
      baseUrl: widget.repo.prefs.baseUrl(),
      deviceToken: token,
      checkinExpiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
    );
    try {
      final started = await widget.tracking.start();
      if (!mounted) return;
      if (started) {
        setState(() => _active = true);
      } else {
        setState(() {
          _active = false;
          _error = context.pilotL10n.pilotGpsStartFailed;
        });
      }
    } on PlatformException catch (e) {
      debugPrint('TrackingScreen._bootstrap start PlatformException: $e');
      if (mounted) {
        setState(() {
          _active = false;
          _error = context.pilotL10n.pilotGpsStartFailed;
        });
      }
    } catch (e) {
      debugPrint('TrackingScreen._bootstrap start error: $e');
      if (mounted) {
        setState(() {
          _active = false;
          _error = context.pilotL10n.pilotGpsStartFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _endFlight() async {
    setState(() => _error = null);
    final l10n = context.pilotL10n;
    if (mounted && !AppConfig.screenshotTest) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.pilotEndFlightConfirmTitle(widget.tail)),
          actions: [
            TextButton(
              key: FlightVisTestKeys.trackingStopCancel,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              key: FlightVisTestKeys.trackingStopConfirm,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.pilotEndFlightConfirmAction),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await widget.tracking.stop();
      if (AppConfig.screenshotTest) {
        if (mounted) widget.onStopped();
        await widget.repo.prefs.setActiveFlightId(null);
        return;
      }
      await widget.repo.client.endFlight(widget.flightId);
      await widget.repo.prefs.setActiveFlightId(null);
      if (mounted) widget.onStopped();
    } on FlightVisException catch (e) {
      if (e.statusCode == 409 || e.statusCode == 404) {
        await widget.tracking.stop();
        await widget.repo.prefs.setActiveFlightId(null);
        if (mounted) widget.onStopped();
        return;
      }
      if (!mounted) return;
      setState(() => _error = localizeApiException(context.pilotL10n, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final mapHeight = (screenHeight * 0.30).clamp(168.0, 260.0);

    return Scaffold(
      key: FlightVisTestKeys.trackingScreen,
      appBar: AppBar(title: Text(l10n.pilotTrackingTitle)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: _mapPointerActive
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.pilotTailLine(widget.tail),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          _active ? Icons.gps_fixed : Icons.gps_off,
                          size: 16,
                          color: _active ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _active
                                ? l10n.pilotBroadcasting
                                : l10n.pilotBroadcastingPaused,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TrackingMapCard(
                      client: widget.repo.client,
                      prefs: widget.repo.prefs,
                      ownTail: widget.tail,
                      trailMinutesOverride: _trailMinutes,
                      clubDefaultMinutes: _clubTrailMinutesDefault,
                      fixSource: widget.fixSource ?? widget.tracking.fixSource,
                      deviceLocationProvider: widget.deviceLocationProvider,
                      onSessionExpired: widget.onSessionExpired,
                      mapHeight: mapHeight,
                      tileProvider: widget.tileProvider,
                      pollInterval: widget.mapPollInterval,
                      enablePolling: widget.enableMapPolling,
                      initialOwnFixes: widget.initialOwnFixes,
                      initialRemoteFlights: widget.initialRemoteFlights,
                      onMapPointerActiveChanged: (active) {
                        if (_mapPointerActive != active && mounted) {
                          setState(() => _mapPointerActive = active);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    TrailLengthChips(
                      selectedMinutes: _trailMinutes,
                      clubDefaultMinutes: _clubTrailMinutesDefault,
                      onSelected: _onSelectTrail,
                    ),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton(
                      key: FlightVisTestKeys.trackingStop,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      onPressed: _endFlight,
                      child: Text(l10n.pilotStop),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}