import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/flight_vis_client.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../services/tracking_service.dart';

class TrackingScreen extends StatefulWidget {
  const TrackingScreen({
    super.key,
    required this.repo,
    required this.flightId,
    required this.tail,
    required this.tracking,
    required this.onStopped,
  });

  final AppRepository repo;
  final String flightId;
  final String tail;
  final TrackingService tracking;
  final VoidCallback onStopped;

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  bool _active = false;
  String? _error;
  String? _missingTokenMessage;
  Timer? _poll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _missingTokenMessage = context.pilotL10n.pilotDeviceTokenMissing;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final on = await widget.tracking.isTracking();
      if (mounted) setState(() => _active = on);
    });
  }

  Future<void> _bootstrap() async {
    final token = await widget.repo.secure.readDeviceToken();
    if (token == null) {
      if (mounted) setState(() => _error = _missingTokenMessage);
      return;
    }
    await widget.tracking.initForFlight(
      baseUrl: widget.repo.prefs.baseUrl(),
      deviceToken: token,
    );
    try {
      await widget.tracking.start();
      setState(() => _active = true);
    } on PlatformException {
      setState(() => _error = 'Could not start GPS — check location permissions.');
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _endFlight() async {
    setState(() => _error = null);
    try {
      await widget.tracking.stop();
      await widget.repo.client.endFlight(widget.flightId);
      await widget.repo.prefs.setActiveFlightId(null);
      if (mounted) widget.onStopped();
    } on FlightVisException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pilotTrackingTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.pilotTailLine(widget.tail), style: Theme.of(context).textTheme.titleLarge),
            Text(l10n.pilotFlightIdLine(widget.flightId)),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  _active ? Icons.gps_fixed : Icons.gps_off,
                  color: _active ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(_active ? l10n.pilotBroadcasting : l10n.pilotBroadcastingPaused),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const Spacer(),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: _endFlight,
              child: Text(l10n.pilotStop),
            ),
          ],
        ),
      ),
    );
  }
}