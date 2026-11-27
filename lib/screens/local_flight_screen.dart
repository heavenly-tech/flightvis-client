import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/live_trails_source.dart';
import '../map/own_trail_buffer.dart';
import '../models/local_flight.dart';
import '../services/app_repository.dart';
import '../services/device_location_provider.dart';
import '../services/flight_start_mode.dart';
import '../services/local_flight_recorder.dart';
import '../storage/local_flight_store.dart';
import '../widgets/tracking_map_card.dart';

/// Active local-only flight recording screen.
///
/// Used when starting a flight signed out or signed in without a club check-in:
/// records GPS fixes purely on-device via [LocalFlightRecorder] and persists a
/// [LocalFlight] to [LocalFlightStore] when finished. Never calls
/// `POST /api/flights` and never starts Traccar upload.
class LocalFlightScreen extends StatefulWidget {
  const LocalFlightScreen({
    super.key,
    required this.repo,
    required this.localRecorder,
    required this.localFlightStore,
    required this.localReason,
    required this.onStopped,
    this.storageBucket,
    this.tail,
    this.onSessionExpired,
    this.deviceLocationProvider,
    this.tileProvider,
    this.enableMapPolling,
    this.mapPollInterval = const Duration(seconds: 5),
    this.initialOwnFixes = const [],
    this.initialRemoteFlights = const [],
    this.clock,
  });

  final AppRepository repo;
  final LocalFlightRecorder localRecorder;
  final LocalFlightStore localFlightStore;
  final LocalFlightReason localReason;
  final VoidCallback onStopped;
  final String? storageBucket;
  final String? tail;
  final VoidCallback? onSessionExpired;
  final DeviceLocationProvider? deviceLocationProvider;
  final TileProvider? tileProvider;
  final bool? enableMapPolling;
  final Duration mapPollInterval;
  final List<LocalFix> initialOwnFixes;
  final List<LiveTrailFlight> initialRemoteFlights;
  final DateTime Function()? clock;

  @override
  State<LocalFlightScreen> createState() => _LocalFlightScreenState();
}

class _LocalFlightScreenState extends State<LocalFlightScreen> {
  late int _startedAtMs;
  bool _active = false;
  bool _stopping = false;
  String? _error;
  bool _mapPointerActive = false;
  final List<LocalFix> _liveFixes = [];
  StreamSubscription<LocalFix>? _fixSub;

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _startedAtMs = _now().millisecondsSinceEpoch;
    _liveFixes.addAll(widget.initialOwnFixes);
    _fixSub = widget.localRecorder.fixSource.watchFixes().listen((fix) {
      if (fix.hasValidCoordinates) {
        _liveFixes.add(fix);
      }
    });
    unawaited(_startRecording());
  }

  @override
  void dispose() {
    unawaited(_fixSub?.cancel());
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      final ok = await widget.localRecorder.start();
      if (!mounted) return;
      if (ok) {
        setState(() {
          _active = true;
          _error = null;
        });
      } else {
        setState(() {
          _active = false;
          _error = context.pilotL10n.localFlightRecordingFailed;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LocalFlightScreen._startRecording failed: $e');
      }
      if (!mounted) return;
      setState(() {
        _active = false;
        _error = context.pilotL10n.localFlightRecordingFailed;
      });
    }
  }

  List<LocalFix> _mergeFixes(List<LocalFix> nativeFixes) {
    final byKey = <String, LocalFix>{};
    for (final f in [..._liveFixes, ...nativeFixes]) {
      if (!f.hasValidCoordinates) continue;
      final key =
          '${f.timeMs}|${f.latitude.toStringAsFixed(6)}|${f.longitude.toStringAsFixed(6)}';
      byKey[key] = f;
    }
    final merged = byKey.values.toList()
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return LocalFlight.capFixes(merged);
  }

  Future<void> _stopFlight() async {
    if (_stopping) return;
    final l10n = context.pilotL10n;
    if (mounted && !AppConfig.screenshotTest) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.localFlightEndConfirmTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              key: FlightVisTestKeys.localFlightStopConfirm,
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

    setState(() => _stopping = true);
    try {
      final nativeFixes = await widget.localRecorder.stop();
      final mergedFixes = _mergeFixes(nativeFixes);
      final endedAtMs = _now().millisecondsSinceEpoch;
      final flight = LocalFlight(
        id: 'local_$_startedAtMs',
        startedAtMs: _startedAtMs,
        endedAtMs: endedAtMs,
        tail: LocalFlight.sanitizeTail(widget.tail),
        fixes: mergedFixes,
      );
      await widget.localFlightStore.save(
        flight,
        bucket: widget.storageBucket,
      );
      if (mounted) widget.onStopped();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LocalFlightScreen._stopFlight failed: $e');
      }
      if (mounted) {
        setState(() {
          _stopping = false;
          _error = context.pilotL10n.errorGeneric;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final sanitizedTail = LocalFlight.sanitizeTail(widget.tail);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final mapHeight = (screenHeight * 0.36).clamp(200.0, 340.0);

    // Signed-out local flights use the anonymous public-only source (zero auth
    // headers, zero club/flight endpoints). Signed-in without check-in may view
    // Club + Público layers while recording strictly locally.
    final LiveTrailsSource trailsSource =
        widget.localReason == LocalFlightReason.signedOut
            ? PublicOnlyLiveTrailsSource(widget.repo.client)
            : AuthenticatedLiveTrailsSource(widget.repo.client);

    return Scaffold(
      key: FlightVisTestKeys.localFlightScreen,
      appBar: AppBar(title: Text(l10n.localFlightScreenTitle)),
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
                      sanitizedTail != null
                          ? l10n.pilotTailLine(sanitizedTail)
                          : l10n.localFlightNoTail,
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
                                ? l10n.localFlightRecordingActive
                                : l10n.pilotBroadcastingPaused,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (widget.localReason == LocalFlightReason.noClubCheckin) ...[
                      const SizedBox(height: 8),
                      Card(
                        key: FlightVisTestKeys.localFlightNoClubNote,
                        margin: EdgeInsets.zero,
                        color: theme.colorScheme.secondaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 18,
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l10n.localFlightNoClubNote,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TrackingMapCard(
                      client: widget.repo.client,
                      prefs: widget.repo.prefs,
                      ownTail: sanitizedTail,
                      trailMinutesOverride: -1,
                      clubDefaultMinutes: null,
                      fixSource: widget.localRecorder.fixSource,
                      trailsSource: trailsSource,
                      deviceLocationProvider: widget.deviceLocationProvider,
                      onSessionExpired:
                          widget.localReason == LocalFlightReason.noClubCheckin
                              ? widget.onSessionExpired
                              : null,
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
                      key: FlightVisTestKeys.localFlightStop,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      onPressed: _stopping ? null : _stopFlight,
                      child: Text(l10n.localFlightStopAction),
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
