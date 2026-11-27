import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../ci_test_keys.dart';
import '../l10n/api_errors.dart';
import '../l10n/pilot_l10n.dart';
import '../map/own_trail_buffer.dart';
import '../services/app_repository.dart';
import '../services/device_location_provider.dart';
import '../services/fix_upload_worker.dart';
import '../services/local_fix_source.dart';
import '../services/tracking_lifecycle.dart';
import '../services/tracking_service.dart';
import '../storage/fix_upload_queue.dart';
import '../storage/local_flight_store.dart';
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
    this.flightMode = 'club',
    this.accountBucket = LocalFlightStore.guestBucket,
    this.uploadQueue,
    this.uploadWorker,
    this.stopDrainTimeout = FixUploadWorker.defaultStopDrainTimeout,
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

  /// `'club'` or `'personal'` (club-less / Piloto público).
  final String flightMode;

  /// Scoped account bucket for the persisted store-and-forward upload queue.
  final String accountBucket;

  /// Optional injectable store-and-forward upload queue for tests.
  final FixUploadQueueStore? uploadQueue;

  /// Optional injectable store-and-forward upload worker for tests.
  final FixUploadWorker? uploadWorker;

  /// Maximum total time budget for draining pending fixes before `endFlight`
  /// on Stop (H-8; defaults to 60 s).
  final Duration stopDrainTimeout;

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
  bool _stopping = false;
  bool _sendingPending = false;
  String? _error;
  String? _missingTokenMessage;
  Timer? _poll;
  int? _trailMinutes;
  int? _confirmedTrailMinutes;
  int _trailRequestSeq = 0;
  bool _mapPointerActive = false;

  /// Store-and-forward state for broadcast fixes Traccar failed to deliver
  /// (offline / 429 / 5xx).
  FixUploadWorker? _ownedUploadWorker;
  StreamSubscription<LocalFix>? _fixSub;
  final List<LocalFix> _unconfirmedLiveFixes = [];
  bool _traccarDegraded = false;
  bool _traccarRateLimited = false;
  String? _activeDeviceToken;

  bool get _isPersonalFlight => widget.flightMode == 'personal';

  FixUploadWorker? get _uploadWorker =>
      widget.uploadWorker ?? _ownedUploadWorker;

  LocalFixSource get _effectiveFixSource =>
      widget.fixSource ?? widget.tracking.fixSource;

  int? get _clubTrailMinutesDefault => _isPersonalFlight
      ? 5
      : (widget.repo.client.clubTrailMinutesDefault ??
          widget.repo.prefs.clubTrailMinutesDefault());

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
    _initUploadWorker();
    _bootstrap();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      _startStatusPoll();
    } else {
      _uploadWorker?.pause();
    }
  }

  void _initUploadWorker() {
    if (AppConfig.screenshotTest) return;
    if (widget.uploadWorker == null) {
      final queue = widget.uploadQueue ??
          FileFixUploadQueueStore(accountBucket: widget.accountBucket);
      _ownedUploadWorker = FixUploadWorker(
        queue: queue,
        // H-8: authorize uploads ONLY when both TrackingScreen's flightId and
        // persisted prefs.activeFlightId agree on the currently open flight.
        activeFlightIdProvider: () {
          final prefId = widget.repo.prefs.activeFlightId()?.trim();
          if (prefId != widget.flightId) return null;
          return widget.flightId;
        },
        uploadBatch: (batch, {required String flightMode}) async {
          final token =
              await widget.repo.readDeviceTokenForMode(flightMode) ??
                  _activeDeviceToken;
          return widget.repo.client.ingestBatch(
            [for (final f in batch) f.toIngestJson()],
            deviceToken: token,
          );
        },
        onStateChanged: () {
          if (mounted) setState(() {});
        },
      );
    }
    _fixSub = _effectiveFixSource.watchFixes().listen(_onLiveFixCaptured);
    unawaited(_syncNativeQueueAndPrune(triggerDrain: false));
  }

  Future<void> _syncNativeQueueAndPrune({bool triggerDrain = true}) async {
    final worker = _uploadWorker;
    if (worker == null) return;
    try {
      await widget.tracking.nativeFixQueue.importIntoStore(worker.queue);
    } catch (_) {}
    try {
      await worker.queue.pruneOrphaned(activeFlightId: widget.flightId);
    } catch (_) {}
    final pending = await worker.refreshPendingCount();
    if (triggerDrain && pending > 0 && !worker.isPaused) {
      unawaited(worker.drain());
    }
  }

  void _onLiveFixCaptured(LocalFix fix) {
    if (!fix.hasValidCoordinates) return;
    if (_traccarDegraded) {
      unawaited(
        _uploadWorker?.enqueue(
          QueuedFixInput.fromLocalFix(
            fix,
            flightId: widget.flightId,
            flightMode: widget.flightMode,
          ),
          triggerFlush: false,
        ),
      );
      return;
    }
    _unconfirmedLiveFixes.add(fix);
    if (_unconfirmedLiveFixes.length > 120) {
      _unconfirmedLiveFixes.removeRange(
        0,
        _unconfirmedLiveFixes.length - 120,
      );
    }
  }

  Future<void> _enqueueUnconfirmedFixes({bool includeRecentNative = false}) async {
    final worker = _uploadWorker;
    if (worker == null) return;
    final candidates = <LocalFix>[..._unconfirmedLiveFixes];
    _unconfirmedLiveFixes.clear();
    if (includeRecentNative) {
      final recent = await _effectiveFixSource.getRecentFixes();
      candidates.addAll(recent);
    }
    if (candidates.isEmpty) return;
    await worker.enqueueAll(
      candidates.map(
        (f) => QueuedFixInput.fromLocalFix(
          f,
          flightId: widget.flightId,
          flightMode: widget.flightMode,
        ),
      ),
      triggerFlush: false,
    );
  }

  void _startStatusPoll() {
    if (AppConfig.screenshotTest) return;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onForegroundResumed());
      _startStatusPoll();
    } else {
      _poll?.cancel();
      _poll = null;
      _uploadWorker?.pause();
    }
  }

  Future<void> _onForegroundResumed() async {
    await _tick();
    if (!mounted) return;
    await _syncNativeQueueAndPrune(triggerDrain: false);
    if (!mounted) return;
    if (_traccarDegraded) {
      await _enqueueUnconfirmedFixes(includeRecentNative: true);
    }
    await _uploadWorker?.resume();
  }

  Future<void> _onSelectTrail(int? minutes) async {
    if (minutes == _trailMinutes) return;
    final seq = ++_trailRequestSeq;
    setState(() => _trailMinutes = minutes);
    try {
      final token = _activeDeviceToken ??
          await widget.repo.readDeviceTokenForMode(widget.flightMode);
      final confirmed = await widget.repo.client.setFlightTrail(
        widget.flightId,
        minutes,
        deviceToken: token,
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
    _uploadWorker?.pause();
    await widget.tracking.stop();
    await widget.repo.prefs.setActiveFlightId(null);
    if (mounted) widget.onStopped();
  }

  Future<void> _tick() async {
    if (!mounted || _stopping) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!_isPersonalFlight &&
        checkinExpired(
          expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
          nowMs: nowMs,
        )) {
      await _haltTracking();
      return;
    }
    final logStatus = await widget.tracking.pollIngestStatus();
    if (logStatus.requiresStop) {
      await _haltTracking();
      return;
    }
    if (logStatus.sawFailure) {
      _traccarDegraded = true;
      if (logStatus.sawRateLimited) {
        _traccarRateLimited = true;
      }
      await _enqueueUnconfirmedFixes();
    }
    if (logStatus.sawNetworkRestored || logStatus.sawSuccess) {
      if (logStatus.sawSuccess) {
        _unconfirmedLiveFixes.clear();
        _traccarDegraded = false;
        _traccarRateLimited = false;
      }
      unawaited(_uploadWorker?.onConnectivityRestored());
    }
    final on = await widget.tracking.isTracking();
    if (mounted) setState(() => _active = on);
  }

  Future<void> _bootstrap() async {
    final expiresMs = _isPersonalFlight
        ? null
        : widget.repo.prefs.checkinExpiresAtMs();
    if (!_isPersonalFlight &&
        checkinExpired(
          expiresAtMs: expiresMs,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        )) {
      await _haltTracking();
      return;
    }
    final token = (await widget.repo.readDeviceTokenForMode(widget.flightMode))
        ?.trim();
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _error = _missingTokenMessage);
      return;
    }
    _activeDeviceToken = token;
    await widget.tracking.initForFlight(
      baseUrl: widget.repo.prefs.baseUrl(),
      deviceToken: token,
      checkinExpiresAtMs: expiresMs,
      flightId: widget.flightId,
      flightMode: widget.flightMode,
    );
    try {
      final started = await widget.tracking.start();
      if (!mounted) return;
      if (started) {
        setState(() => _active = true);
        await _syncNativeQueueAndPrune(triggerDrain: false);
        unawaited(_uploadWorker?.resume());
      } else {
        setState(() {
          _active = false;
          _error = context.pilotL10n.pilotGpsStartFailed;
        });
      }
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('TrackingScreen._bootstrap start PlatformException: $e');
      }
      if (mounted) {
        setState(() {
          _active = false;
          _error = context.pilotL10n.pilotGpsStartFailed;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('TrackingScreen._bootstrap start error: $e');
      }
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
    unawaited(_fixSub?.cancel());
    _ownedUploadWorker?.dispose();
    super.dispose();
  }

  Future<void> _endFlight() async {
    if (_stopping) return;
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
    if (mounted) {
      setState(() {
        _stopping = true;
        _error = null;
      });
    }
    try {
      // Stop live GPS acquisition & clear native active flight tag so no new
      // fixes are captured while draining; any already-persisted native fixes
      // remain until imported below.
      await widget.tracking.stop();
      if (AppConfig.screenshotTest) {
        await widget.repo.prefs.setActiveFlightId(null);
        if (mounted) widget.onStopped();
        return;
      }

      // H-8: fully drain the queue for widget.flightId (honouring 429
      // Retry-After/backoff up to stopDrainTimeout, default 60s) BEFORE calling
      // POST /api/flights/{id}/end. Any remaining fixes if the cap is hit stay
      // tagged to widget.flightId locally and are never posted to later flights.
      final worker = _uploadWorker;
      if (worker != null) {
        if (_traccarDegraded) {
          await _enqueueUnconfirmedFixes();
        }
        var importedNativeCount = 0;
        try {
          final res =
              await widget.tracking.nativeFixQueue.importIntoStore(worker.queue);
          importedNativeCount = res.readCount;
        } catch (_) {}
        final hasInjectedQueue =
            widget.uploadQueue != null || widget.uploadWorker != null;
        final pending = (worker.pendingCount > 0 ||
                importedNativeCount > 0 ||
                _traccarDegraded ||
                hasInjectedQueue)
            ? await worker.refreshPendingCount()
            : 0;
        if (pending > 0) {
          if (mounted) setState(() => _sendingPending = true);
          try {
            await worker.drainForStop(timeout: widget.stopDrainTimeout);
          } catch (_) {}
        }
      }

      final token = _activeDeviceToken ??
          await widget.repo.readDeviceTokenForMode(widget.flightMode);
      try {
        await widget.repo.client.endFlight(widget.flightId, deviceToken: token);
      } on SocketException {
        // Offline: finish locally anyway; leftovers stay tagged to widget.flightId.
      } on TimeoutException {
        // Timed out: finish locally anyway.
      } on http.ClientException {
        // Network error: finish locally anyway.
      }
      await widget.repo.prefs.setActiveFlightId(null);
      if (mounted) {
        setState(() {
          _stopping = false;
          _sendingPending = false;
        });
        widget.onStopped();
      }
    } on FlightVisException catch (e) {
      if (e.statusCode == 409 || e.statusCode == 404) {
        await widget.tracking.stop();
        await widget.repo.prefs.setActiveFlightId(null);
        if (mounted) {
          setState(() {
            _stopping = false;
            _sendingPending = false;
          });
          widget.onStopped();
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _stopping = false;
        _sendingPending = false;
        _error = localizeApiException(context.pilotL10n, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final mapHeight = (screenHeight * 0.30).clamp(168.0, 260.0);
    final pendingQueueCount = _uploadWorker?.pendingCount ?? 0;
    final showRateLimited =
        _traccarRateLimited || (_uploadWorker?.isRateLimited ?? false);

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
                    if (_sendingPending) ...[
                      const SizedBox(height: 6),
                      Row(
                        key: FlightVisTestKeys.trackingSendingPending,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.trackingSendingPendingFixes,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (showRateLimited) ...[
                      const SizedBox(height: 6),
                      Text(
                        l10n.trackingRateLimitedNotice,
                        key: FlightVisTestKeys.trackingRateLimitBanner,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                    if (pendingQueueCount > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        l10n.trackingQueuedFixesPending(pendingQueueCount),
                        key: FlightVisTestKeys.trackingQueueBanner,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TrackingMapCard(
                      client: widget.repo.client,
                      prefs: widget.repo.prefs,
                      ownTail: widget.tail,
                      trailMinutesOverride: _trailMinutes,
                      clubDefaultMinutes: _clubTrailMinutesDefault,
                      fixSource: _effectiveFixSource,
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
                      onPressed: _stopping ? null : _endFlight,
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
