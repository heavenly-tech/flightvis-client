import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../api/flight_vis_client.dart';
import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/globe_bridge.dart';
import '../map/live_trails_source.dart';
import '../map/own_trail_buffer.dart';
import '../services/app_repository.dart';
import '../services/device_location_provider.dart';
import '../widgets/globe_view.dart';
import '../widgets/tracking_map_card.dart';

/// Standalone live map reachable from the Home Hub without a check-in or an
/// active flight.
///
/// - Signed-out / guest mode (`loggedIn == false`): uses
///   [PublicOnlyLiveTrailsSource] (`GET /api/public/live-trails`, no auth
///   headers), Público ON by default, Club disabled with sign-in hint.
/// - Signed-in approved pilot (`loggedIn == true`): uses
///   [AuthenticatedLiveTrailsSource] (`GET /api/me/live-trails`), showing Mío,
///   Club (no coords required), and Público (uses device last-known location).
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({
    super.key,
    required this.repo,
    required this.loggedIn,
    this.onSessionExpired,
    this.deviceLocationProvider,
    this.tileProvider,
    this.globeControllerFactory,
    this.isOnline,
    this.globeReadyTimeout = globeBridgeReadyTimeout,
    this.globeThrottleInterval = globeBridgeThrottleInterval,
    this.externalUrlLauncher,
    this.enableMapPolling,
    this.mapPollInterval = const Duration(seconds: 5),
    this.initialOwnFixes = const [],
    this.initialRemoteFlights = const [],
  });

  final AppRepository repo;
  final bool loggedIn;
  final VoidCallback? onSessionExpired;
  final DeviceLocationProvider? deviceLocationProvider;
  final TileProvider? tileProvider;
  final GlobeViewControllerFactory? globeControllerFactory;
  final GlobeConnectivityCheck? isOnline;
  final Duration globeReadyTimeout;
  final Duration globeThrottleInterval;
  final GlobeExternalUrlLauncher? externalUrlLauncher;
  final bool? enableMapPolling;
  final Duration mapPollInterval;
  final List<LocalFix> initialOwnFixes;
  final List<LiveTrailFlight> initialRemoteFlights;

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  bool _mapPointerActive = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final LiveTrailsSource source = widget.loggedIn
        ? AuthenticatedLiveTrailsSource(widget.repo.client)
        : PublicOnlyLiveTrailsSource(widget.repo.client);

    return Scaffold(
      key: FlightVisTestKeys.liveMapScreen,
      appBar: AppBar(title: Text(l10n.pilotHubLiveMapTitle)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final reserved = widget.loggedIn ? 140.0 : 170.0;
            final mapHeight =
                (constraints.maxHeight - reserved).clamp(240.0, 560.0);
            return SingleChildScrollView(
              physics: _mapPointerActive
                  ? const NeverScrollableScrollPhysics()
                  : null,
              padding: const EdgeInsets.all(16),
              child: TrackingMapCard(
                client: widget.repo.client,
                prefs: widget.repo.prefs,
                ownTail: null,
                trailMinutesOverride: 0,
                clubDefaultMinutes: 0,
                fixSource: null,
                trailsSource: source,
                deviceLocationProvider: widget.deviceLocationProvider,
                onSessionExpired:
                    widget.loggedIn ? widget.onSessionExpired : null,
                enable3dToggle: true,
                mapHeight: mapHeight,
                tileProvider: widget.tileProvider,
                globeControllerFactory: widget.globeControllerFactory,
                isOnline: widget.isOnline,
                globeReadyTimeout: widget.globeReadyTimeout,
                globeThrottleInterval: widget.globeThrottleInterval,
                externalUrlLauncher: widget.externalUrlLauncher,
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
            );
          },
        ),
      ),
    );
  }
}
