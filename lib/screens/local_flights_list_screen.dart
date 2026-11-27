import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/live_trails_source.dart';
import '../models/local_flight.dart';
import '../services/app_repository.dart';
import '../storage/local_flight_store.dart';
import '../widgets/tracking_map_card.dart';

/// Displays flights recorded locally on the device and lets the pilot view any
/// saved track statically on the map (own trail only).
class LocalFlightsListScreen extends StatefulWidget {
  const LocalFlightsListScreen({
    super.key,
    required this.repo,
    required this.store,
    this.tileProvider,
  });

  final AppRepository repo;
  final LocalFlightStore store;
  final TileProvider? tileProvider;

  @override
  State<LocalFlightsListScreen> createState() => _LocalFlightsListScreenState();
}

class _LocalFlightsListScreenState extends State<LocalFlightsListScreen> {
  List<LocalFlight> _flights = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await widget.store.listFlights();
    if (!mounted) return;
    setState(() {
      _flights = items;
      _loading = false;
    });
  }

  String _formatDate(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      key: FlightVisTestKeys.localFlightsListScreen,
      appBar: AppBar(title: Text(l10n.pilotHubLocalFlightsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _flights.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.localFlightsEmpty,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _flights.length,
                  itemBuilder: (context, index) {
                    final flight = _flights[index];
                    final mins = flight.duration.inMinutes;
                    final title = flight.tail ?? l10n.localFlightNoTail;
                    final subtitle =
                        '${_formatDate(flight.startedAtMs)} · ${l10n.localFlightDurationMinutes(mins)} · ${l10n.localFlightPointsCount(flight.fixes.length)}';
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.route),
                        title: Text(title),
                        subtitle: Text(subtitle),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => _LocalFlightDetailScreen(
                              repo: widget.repo,
                              flight: flight,
                              dateLabel: _formatDate(flight.startedAtMs),
                              tileProvider: widget.tileProvider,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _LocalFlightDetailScreen extends StatelessWidget {
  const _LocalFlightDetailScreen({
    required this.repo,
    required this.flight,
    required this.dateLabel,
    this.tileProvider,
  });

  final AppRepository repo;
  final LocalFlight flight;
  final String dateLabel;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final title = flight.tail ?? l10n.localFlightNoTail;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$dateLabel · ${l10n.localFlightDurationMinutes(flight.duration.inMinutes)} · ${l10n.localFlightPointsCount(flight.fixes.length)}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              TrackingMapCard(
                client: repo.client,
                prefs: repo.prefs,
                ownTail: flight.tail,
                trailMinutesOverride: -1,
                clubDefaultMinutes: null,
                fixSource: null,
                trailsSource: const StaticLiveTrailsSource(),
                showLayerControls: false,
                enablePolling: false,
                mapHeight: 360,
                tileProvider: tileProvider,
                initialOwnFixes: flight.fixes,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.localFlightUploadSoon,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
