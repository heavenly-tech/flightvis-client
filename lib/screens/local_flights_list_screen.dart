import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../map/live_trails_source.dart';
import '../models/local_flight.dart';
import '../services/app_repository.dart';
import '../storage/local_flight_migration.dart';
import '../storage/local_flight_store.dart';
import '../widgets/tracking_map_card.dart';

/// Displays flights recorded locally on the device for [accountBucket] only,
/// lets the pilot view any saved track statically on the map (own trail only),
/// delete individual flights with confirmation, and (when signed in) handle:
/// - the one-time adopt-or-delete choice for migrated pre-#11 legacy flights
///   (visible only to the first signed-in account / claimant, never to guests),
/// - moving unacknowledged guest-recorded flights into the signed-in account
///   or persistently leaving them on the phone.
class LocalFlightsListScreen extends StatefulWidget {
  const LocalFlightsListScreen({
    super.key,
    required this.repo,
    required this.store,
    this.accountBucket = LocalFlightStore.guestBucket,
    this.tileProvider,
  });

  final AppRepository repo;
  final LocalFlightStore store;
  final String accountBucket;
  final TileProvider? tileProvider;

  @override
  State<LocalFlightsListScreen> createState() => _LocalFlightsListScreenState();
}

class _LocalFlightsListScreenState extends State<LocalFlightsListScreen> {
  List<LocalFlight> _flights = const [];
  int _legacyCount = 0;
  Set<String> _unacknowledgedGuestIds = const {};
  bool _busy = false;
  bool _loading = true;

  bool get _isSignedInBucket =>
      !LocalFlightStore.isReservedBucket(widget.accountBucket) &&
      LocalFlightStore.sanitizeBucket(widget.accountBucket) !=
          LocalFlightStore.guestBucket;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LocalFlightsListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountBucket != widget.accountBucket ||
        oldWidget.store != widget.store) {
      _load();
    }
  }

  Future<void> _load() async {
    final items = await widget.store.listFlights(bucket: widget.accountBucket);
    var legacyCount = 0;
    var guestIds = const <String>{};
    if (_isSignedInBucket) {
      legacyCount = await LocalFlightMigration.claimOrCheckLegacyFlights(
        store: widget.store,
        prefs: widget.repo.prefs,
        accountBucket: widget.accountBucket,
      );
      final guestItems = await LocalFlightMigration.unacknowledgedGuestFlights(
        store: widget.store,
        prefs: widget.repo.prefs,
        accountBucket: widget.accountBucket,
      );
      guestIds = guestItems.map((f) => f.id).toSet();
    }
    if (!mounted) return;
    setState(() {
      _flights = items;
      _legacyCount = legacyCount;
      _unacknowledgedGuestIds = guestIds;
      _loading = false;
    });
  }

  Future<void> _adoptLegacyFlights() async {
    if (_busy || !_isSignedInBucket || _legacyCount <= 0) return;
    setState(() => _busy = true);
    try {
      await LocalFlightMigration.adoptClaimedLegacyFlights(
        store: widget.store,
        prefs: widget.repo.prefs,
        accountBucket: widget.accountBucket,
      );
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmDeleteLegacyFlights() async {
    if (_busy || !_isSignedInBucket || _legacyCount <= 0) return;
    final l10n = context.pilotL10n;
    final count = _legacyCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: FlightVisTestKeys.localFlightsLegacyDeleteConfirmDialog,
        title: Text(l10n.localFlightsLegacyDeleteConfirmTitle(count)),
        content: Text(l10n.localFlightsLegacyDeleteConfirmBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: FlightVisTestKeys.localFlightsLegacyDeleteConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.localFlightDeleteConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await LocalFlightMigration.deleteClaimedLegacyFlights(
        store: widget.store,
        prefs: widget.repo.prefs,
        accountBucket: widget.accountBucket,
      );
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _moveGuestFlightsToAccount() async {
    if (_busy || !_isSignedInBucket || _unacknowledgedGuestIds.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.store.moveFlights(
        fromBucket: LocalFlightStore.guestBucket,
        toBucket: widget.accountBucket,
        flightIds: _unacknowledgedGuestIds,
      );
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _keepGuestFlightsOnPhone() async {
    if (_busy || !_isSignedInBucket || _unacknowledgedGuestIds.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.repo.prefs.markGuestFlightsKeptOnPhone(
        widget.accountBucket,
        _unacknowledgedGuestIds,
      );
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmDelete(LocalFlight flight) async {
    final l10n = context.pilotL10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: FlightVisTestKeys.localFlightDeleteDialog,
        title: Text(l10n.localFlightDeleteConfirmTitle),
        content: Text(l10n.localFlightDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: FlightVisTestKeys.localFlightDeleteConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.localFlightDeleteConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.store.deleteFlight(flight.id, bucket: widget.accountBucket);
    await _load();
  }

  String _formatDate(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  Widget _buildLegacyChoiceBanner(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    return Card(
      key: FlightVisTestKeys.localFlightsLegacyBanner,
      color: theme.colorScheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.history,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.localFlightsLegacyTitle(_legacyCount),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.localFlightsLegacyBody(_legacyCount),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: FlightVisTestKeys.localFlightsLegacyAdopt,
                  onPressed: _busy ? null : _adoptLegacyFlights,
                  child: Text(l10n.localFlightsMoveToAccountAction),
                ),
                OutlinedButton(
                  key: FlightVisTestKeys.localFlightsLegacyDelete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: _busy ? null : _confirmDeleteLegacyFlights,
                  child: Text(l10n.localFlightDeleteConfirmAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuestChoiceBanner(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final guestCount = _unacknowledgedGuestIds.length;
    return Card(
      key: FlightVisTestKeys.localFlightsGuestBanner,
      color: theme.colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.phone_android,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.localFlightsGuestBannerTitle(guestCount),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: FlightVisTestKeys.localFlightsMoveToAccount,
                  onPressed: _busy ? null : _moveGuestFlightsToAccount,
                  child: Text(l10n.localFlightsMoveToAccountAction),
                ),
                OutlinedButton(
                  key: FlightVisTestKeys.localFlightsKeepOnPhone,
                  onPressed: _busy ? null : _keepGuestFlightsOnPhone,
                  child: Text(l10n.localFlightsKeepOnPhoneAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final showLegacyBanner = _isSignedInBucket && _legacyCount > 0;
    final showGuestBanner =
        _isSignedInBucket && _unacknowledgedGuestIds.isNotEmpty;

    return Scaffold(
      key: FlightVisTestKeys.localFlightsListScreen,
      appBar: AppBar(title: Text(l10n.pilotHubLocalFlightsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _flights.isEmpty && !showLegacyBanner && !showGuestBanner
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.localFlightsEmpty,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (showLegacyBanner) _buildLegacyChoiceBanner(context),
                    if (showGuestBanner) _buildGuestChoiceBanner(context),
                    if (_flights.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 32,
                        ),
                        child: Text(
                          l10n.localFlightsEmpty,
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      for (final flight in _flights)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.route),
                            title: Text(flight.tail ?? l10n.localFlightNoTail),
                            subtitle: Text(
                              '${_formatDate(flight.startedAtMs)} · ${l10n.localFlightDurationMinutes(flight.duration.inMinutes)} · ${l10n.localFlightPointsCount(flight.fixes.length)}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: FlightVisTestKeys.localFlightDelete(
                                    flight.id,
                                  ),
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: l10n.localFlightDeleteTooltip,
                                  onPressed: () => _confirmDelete(flight),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
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
                        ),
                  ],
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
