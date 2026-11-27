import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../ci_test_keys.dart';
import '../dev/dev_tools_gate.dart';
import '../l10n/pilot_l10n.dart';
import '../models/local_flight.dart';
import '../services/app_repository.dart';
import '../services/device_location_provider.dart';
import '../services/flight_permissions.dart';
import '../services/flight_start_mode.dart';
import '../services/local_flight_recorder.dart';
import '../state/checkin_gate.dart';
import '../storage/local_flight_store.dart';
import '../util/checkin_expiry_format.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/permission_warning_card.dart';
import 'checkin_screen.dart';
import 'hidden_settings_screen.dart';
import 'live_map_screen.dart';
import 'local_flight_screen.dart';
import 'local_flights_list_screen.dart';
import 'pairing_screen.dart';
import 'personal_flight_start_screen.dart';
import 'tail_picker_screen.dart';

class HomeHubScreen extends StatefulWidget {
  const HomeHubScreen({
    super.key,
    required this.repo,
    required this.onStartFlight,
    required this.onRequestLogin,
    required this.onLogout,
    this.pilot,
    this.accountProfile,
    this.onStartBroadcastFlight,
    this.onSwitchClub,
    this.onLocaleChanged,
    this.onStartLocalFlight,
    this.permissions,
    this.deviceLocationProvider,
    this.localRecorder,
    this.localFlightStore,
    this.sessionExpiredNotice = false,
    this.clubUnavailableNotice = false,
    this.magicLinkNotice,
    this.magicLinkNoticeIsError = false,
    this.localFlightsRevision = 0,
    this.tileProvider,
    this.enableMapPolling,
    this.initialPermissionHintGap,
  });

  final AppRepository repo;
  final PilotProfile? pilot;
  final AccountProfile? accountProfile;
  final void Function(String flightId, String tailLabel) onStartFlight;
  final void Function(
    String flightId,
    String tailLabel, {
    String flightMode,
    int? startedAtMs,
  })? onStartBroadcastFlight;
  final Future<void> Function(AccountMembership membership)? onSwitchClub;
  final VoidCallback onRequestLogin;
  final VoidCallback onLogout;
  final VoidCallback? onLocaleChanged;

  /// Optional callback used by [FlightVisApp] to transition into local flight
  /// recording mode. When omitted (e.g. standalone widget tests), [HomeHubScreen]
  /// pushes [LocalFlightScreen] directly.
  final void Function({String? tail, required LocalFlightReason reason})?
      onStartLocalFlight;

  final FlightPermissionsClient? permissions;
  final DeviceLocationProvider? deviceLocationProvider;
  final LocalFlightRecorder? localRecorder;
  final LocalFlightStore? localFlightStore;

  /// True when startup detected an expired/invalid session (401 or pilot:null).
  final bool sessionExpiredNotice;

  /// True when `/api/club/me` returned 403 `club unavailable` (session kept,
  /// club broadcast disabled until available again).
  final bool clubUnavailableNotice;

  /// Optional status/error banner from an App Link magic-link attempt.
  final String? magicLinkNotice;
  final bool magicLinkNoticeIsError;

  /// Incremented by the app shell when local flights change outside this screen
  /// (e.g. moving guest flights on sign-in) so the count badge refreshes.
  final int localFlightsRevision;

  final TileProvider? tileProvider;
  final bool? enableMapPolling;

  /// Optional pre-seeded OEM permission hint for deterministic golden tests.
  final PermissionGap? initialPermissionHintGap;

  @override
  State<HomeHubScreen> createState() => _HomeHubScreenState();
}

class _HomeHubScreenState extends State<HomeHubScreen>
    with WidgetsBindingObserver {
  int _secretTaps = 0;
  Timer? _tick;
  FlightPermissionStatus? _permissionStatus;
  String? _startError;
  int? _localFlightCount;
  String _selectedMode = 'club';
  bool _switchingClub = false;
  late final LocalFlightStore _fallbackLocalStore;

  FlightPermissionsClient get _permissions =>
      widget.permissions ?? FlightPermissions.instance;

  LocalFlightStore get _localFlightStore =>
      widget.localFlightStore ?? _fallbackLocalStore;

  String get _accountBucket => LocalFlightStore.bucketForPilot(widget.pilot);

  bool get _isClublessAccount => widget.pilot?.isClublessAccount ?? false;

  bool get _hasAccountSession =>
      widget.repo.client.hasAccountSession || widget.accountProfile != null;

  List<AccountMembership> get _activeMemberships =>
      widget.accountProfile?.activeMemberships ?? const [];

  bool get _showModePicker =>
      _loggedIn &&
      !_isClublessAccount &&
      _hasAccountSession &&
      _activeMemberships.isNotEmpty;

  bool get _showClubPicker =>
      _loggedIn &&
      _hasAccountSession &&
      widget.onSwitchClub != null &&
      (_activeMemberships.length >= 2 ||
          (_activeMemberships.length == 1 &&
              widget.accountProfile?.activeMembershipId == null));

  bool get _inPersonalMode =>
      _loggedIn &&
      (_isClublessAccount || (_showModePicker && _selectedMode == 'personal'));

  @override
  void initState() {
    super.initState();
    _fallbackLocalStore = FileLocalFlightStore();
    final savedMode = widget.repo.prefs.preferredFlightMode();
    if (savedMode == 'personal' || savedMode == 'club') {
      _selectedMode = savedMode!;
    }
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
    if (!AppConfig.screenshotTest) {
      _refreshLocalFlightCount();
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant HomeHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!AppConfig.screenshotTest &&
        (LocalFlightStore.bucketForPilot(oldWidget.pilot) != _accountBucket ||
            oldWidget.localFlightsRevision != widget.localFlightsRevision ||
            oldWidget.localFlightStore != widget.localFlightStore)) {
      _refreshLocalFlightCount();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    final status = await _permissions.check();
    if (!mounted) return;
    setState(() => _permissionStatus = status);
  }

  Future<void> _refreshLocalFlightCount() async {
    final bucket = _accountBucket;
    try {
      final flights = await _localFlightStore.listFlights(bucket: bucket);
      if (!mounted || bucket != _accountBucket) return;
      setState(() => _localFlightCount = flights.length);
    } catch (_) {
      // Non-critical count badge; ignore in environments without path_provider.
    }
  }

  CheckinGate get _gate => CheckinGate(
        expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  bool get _loggedIn => widget.pilot != null && widget.pilot!.isApproved;

  void _openHidden() {
    if (!hiddenServerSettingsEnabled) return;
    _secretTaps++;
    if (_secretTaps >= 7) {
      _secretTaps = 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HiddenSettingsScreen(
            repo: widget.repo,
            onLocaleChanged: widget.onLocaleChanged,
          ),
        ),
      );
    }
  }

  void _openLiveMap() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => LiveMapScreen(
          repo: widget.repo,
          loggedIn: _loggedIn,
          deviceLocationProvider: widget.deviceLocationProvider,
          tileProvider: widget.tileProvider,
          enableMapPolling: widget.enableMapPolling,
          onSessionExpired: () {
            Navigator.of(routeContext).maybePop();
            widget.onRequestLogin();
          },
        ),
      ),
    );
  }

  void _notifyStartBroadcast(
    String flightId,
    String tail, {
    String flightMode = 'club',
    int? startedAtMs,
  }) {
    if (widget.onStartBroadcastFlight != null) {
      widget.onStartBroadcastFlight!(
        flightId,
        tail,
        flightMode: flightMode,
        startedAtMs: startedAtMs,
      );
    } else {
      widget.onStartFlight(flightId, tail);
    }
  }

  Future<void> _selectMode(String mode) async {
    if (mode == _selectedMode) return;
    setState(() => _selectedMode = mode);
    await widget.repo.prefs.setPreferredFlightMode(mode);
  }

  Future<void> _openPersonalFlightStart() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => PersonalFlightStartScreen(
          repo: widget.repo,
          pilot: widget.pilot,
          permissions: widget.permissions,
          onFlightStarted: (flight, tail) {
            Navigator.of(routeContext).pop();
            _notifyStartBroadcast(
              flight.id,
              tail,
              flightMode: 'personal',
              startedAtMs: flight.startedAtMs,
            );
          },
        ),
      ),
    );
  }

  Future<void> _startLocalFlow(LocalFlightReason reason) async {
    final confirmedTail = await _showLocalFlightStartDialog(reason);
    if (!mounted || confirmedTail == null) return;
    final sanitized = LocalFlight.sanitizeTail(confirmedTail);

    if (widget.onStartLocalFlight != null) {
      widget.onStartLocalFlight!(tail: sanitized, reason: reason);
      return;
    }

    final recorder = widget.localRecorder ?? PlatformLocalFlightRecorder();
    final bucket = _accountBucket;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => LocalFlightScreen(
          repo: widget.repo,
          localRecorder: recorder,
          localFlightStore: _localFlightStore,
          storageBucket: bucket,
          localReason: reason,
          tail: sanitized,
          deviceLocationProvider: widget.deviceLocationProvider,
          tileProvider: widget.tileProvider,
          enableMapPolling: widget.enableMapPolling,
          onSessionExpired: () {
            Navigator.of(routeContext).maybePop();
            widget.onRequestLogin();
          },
          onStopped: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
    await _refreshLocalFlightCount();
  }

  Future<void> _onTapRecordLocalOnly() async {
    setState(() => _startError = null);
    final status = await _permissions.check();
    if (!status.fineLocationGranted) {
      final granted = await _permissions.requestFineLocation();
      final rechecked = await _permissions.check();
      if (!mounted) return;
      setState(() => _permissionStatus = rechecked);
      if (!granted && !rechecked.fineLocationGranted) {
        setState(() => _startError = context.pilotL10n.permFineRequiredToStart);
        return;
      }
    }
    if (!mounted) return;
    await _startLocalFlow(
      _loggedIn ? LocalFlightReason.noClubCheckin : LocalFlightReason.signedOut,
    );
  }

  Future<void> _openClubPickerSheet() async {
    final memberships = _activeMemberships;
    if (memberships.isEmpty || widget.onSwitchClub == null) return;
    final l10n = context.pilotL10n;
    final activeId = widget.accountProfile?.activeMembershipId;
    final chosen = await showModalBottomSheet<AccountMembership>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.pilotHubClubPickerTitle,
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
            ),
            for (final m in memberships)
              ListTile(
                key: FlightVisTestKeys.clubPickerOption(m.id),
                leading: Icon(
                  m.id == activeId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(m.name),
                subtitle: Text(m.slug),
                onTap: () => Navigator.pop(sheetCtx, m),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _switchingClub = true);
    try {
      await widget.onSwitchClub!(chosen);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(context.pilotL10n.pilotHubClubSwitched(chosen.name)),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _switchingClub = false);
    }
  }

  Future<void> _onTapStartFlight() async {
    setState(() => _startError = null);

    // Foreground (fine) location is the ONLY hard requirement to start.
    // Missing battery/notifications/background only warn in the banner.
    final status = await _permissions.check();
    if (!status.fineLocationGranted) {
      final granted = await _permissions.requestFineLocation();
      final rechecked = await _permissions.check();
      if (!mounted) return;
      setState(() => _permissionStatus = rechecked);
      if (!granted && !rechecked.fineLocationGranted) {
        setState(() => _startError = context.pilotL10n.permFineRequiredToStart);
        return;
      }
    }
    if (!mounted) return;

    final resolution = resolveFlightStartMode(
      pilot: widget.pilot,
      checkinGate: _gate,
      clubUnavailable: widget.clubUnavailableNotice,
      preferPersonalBroadcast: _inPersonalMode,
      hasAccountSession: _hasAccountSession,
    );
    if (resolution.isPersonalBroadcast) {
      await _openPersonalFlightStart();
      return;
    }
    if (resolution.isClubBroadcast) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (routeContext) => TailPickerScreen(
            repo: widget.repo,
            pilot: widget.pilot,
            permissions: widget.permissions,
            onFlightStarted: (flight, tail) {
              Navigator.of(routeContext).pop();
              _notifyStartBroadcast(
                flight.id,
                tail,
                flightMode: 'club',
                startedAtMs: flight.startedAtMs,
              );
            },
          ),
        ),
      );
      return;
    }

    final reason = resolution.localReason ?? LocalFlightReason.signedOut;
    await _startLocalFlow(reason);
  }

  /// Prompts for optional tail before starting local recording.
  /// Returns `null` if cancelled, or `''`/tail string if confirmed.
  Future<String?> _showLocalFlightStartDialog(LocalFlightReason reason) {
    return showDialog<String>(
      context: context,
      builder: (_) => _LocalFlightStartDialog(reason: reason),
    );
  }

  Widget? _checkinBanner(BuildContext context) {
    final l10n = context.pilotL10n;
    final gate = _gate;
    if (!gate.hasCheckin) return null;
    if (gate.isExpired) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.warning_amber),
          title: Text(l10n.pilotCheckInExpired),
          subtitle: Text(l10n.pilotCheckInExpiredRescan),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CheckinScreen(
                repo: widget.repo,
                pilot: widget.pilot,
                permissions: widget.permissions,
                onCheckedIn: () {
                  if (mounted) setState(() {});
                },
                onStartFlight: widget.onStartFlight,
              ),
            ),
          ).then((_) {
            if (mounted) setState(() {});
          }),
        ),
      );
    }
    final until = CheckinExpiryFormat.formatFromEpochMs(gate.expiresAtMs!);
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.verified_user),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.pilotCheckInValidUntil(until))),
          ],
        ),
      ),
    );
  }

  String _clubLine(BuildContext context) {
    final l10n = context.pilotL10n;
    if (_isClublessAccount) {
      return l10n.pilotHubPublicPilotStatus;
    }
    final name =
        widget.repo.prefs.activeClubName() ?? widget.repo.prefs.activeClubSlug();
    if (name != null && name.isNotEmpty) {
      return l10n.pilotHubActiveClub(name);
    }
    return l10n.pilotHubNoClubYet;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final gate = _gate;
    final pilot = widget.pilot;
    final loggedIn = _loggedIn;
    final inPersonalMode = _inPersonalMode;
    final canBroadcastClub =
        loggedIn && gate.canStartFlight && !widget.clubUnavailableNotice;
    final canBroadcastCard = inPersonalMode || canBroadcastClub;
    final broadcastTitle = inPersonalMode
        ? l10n.pilotHubPersonalBroadcastTitle
        : l10n.pilotHubFlightTitle;
    final broadcastSubtitle = inPersonalMode
        ? l10n.pilotHubPersonalBroadcastSubtitle
        : (widget.clubUnavailableNotice
            ? l10n.clubUnavailableNotice
            : (canBroadcastClub
                ? l10n.pilotHubFlightSubtitle
                : (!loggedIn
                    ? l10n.pilotHubFlightBroadcastSignedOut
                    : l10n.pilotHubFlightBroadcastNoCheckIn)));
    final localFlightsSubtitle = _localFlightCount == null
        ? l10n.pilotHubLocalFlightsSubtitle
        : l10n.pilotHubLocalFlightsCount(_localFlightCount!);

    return Scaffold(
      key: FlightVisTestKeys.hub,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _openHidden,
          child: Text(l10n.appName),
        ),
        actions: [
          IconButton(
            onPressed: () => showLanguagePickerSheet(
              context: context,
              repo: widget.repo,
              onChanged: () => widget.onLocaleChanged?.call(),
            ),
            icon: const Icon(Icons.language),
            tooltip: l10n.pilotLanguageTitle,
          ),
          if (loggedIn)
            IconButton(
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
              tooltip: l10n.pilotSignOut,
            )
          else
            TextButton(
              key: FlightVisTestKeys.hubSignIn,
              onPressed: widget.onRequestLogin,
              child: Text(l10n.pilotSignInButton),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            loggedIn ? l10n.pilotHubSignedInAs(pilot!.name) : l10n.pilotHubGuestMode,
          ),
          const SizedBox(height: 4),
          if (_showClubPicker)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _clubLine(context),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: FlightVisTestKeys.hubClubSwitchButton,
                  onPressed: _switchingClub ? null : _openClubPickerSheet,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: Text(l10n.pilotHubClubSwitchButton),
                ),
              ],
            )
          else
            Text(_clubLine(context), style: theme.textTheme.titleMedium),
          if (_showModePicker) ...[
            const SizedBox(height: 10),
            SegmentedButton<String>(
              key: FlightVisTestKeys.hubModePicker,
              segments: [
                ButtonSegment<String>(
                  value: 'club',
                  icon: const Icon(Icons.groups),
                  label: Text(
                    l10n.pilotModeClub,
                    key: FlightVisTestKeys.hubModeClub,
                  ),
                ),
                ButtonSegment<String>(
                  value: 'personal',
                  icon: const Icon(Icons.public),
                  label: Text(
                    l10n.pilotModePublicPilot,
                    key: FlightVisTestKeys.hubModePersonal,
                  ),
                ),
              ],
              selected: {_selectedMode},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  unawaited(_selectMode(selection.first));
                }
              },
            ),
          ],
          const SizedBox(height: 12),
          if (widget.magicLinkNotice != null &&
              widget.magicLinkNotice!.isNotEmpty) ...[
            Card(
              key: FlightVisTestKeys.hubMagicStatusBanner,
              color: widget.magicLinkNoticeIsError
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.magicLinkNotice!,
                  style: TextStyle(
                    color: widget.magicLinkNoticeIsError
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.clubUnavailableNotice) ...[
            Card(
              key: FlightVisTestKeys.hubClubUnavailableBanner,
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.clubUnavailableNotice,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.sessionExpiredNotice && !loggedIn) ...[
            Card(
              key: FlightVisTestKeys.hubSessionExpiredBanner,
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_clock,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.sessionExpiredPrompt,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.onRequestLogin,
                      child: Text(l10n.pilotSignInButton),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_checkinBanner(context) != null) ...[
            _checkinBanner(context)!,
            const SizedBox(height: 12),
          ],
          if (_permissionStatus != null &&
              _permissionStatus!.hasTrackingPermissionGaps) ...[
            PermissionWarningCard(
              status: _permissionStatus!,
              permissions: widget.permissions,
              onChanged: _refreshPermissions,
              initialHintGap: widget.initialPermissionHintGap,
            ),
            const SizedBox(height: 12),
          ],
          if (_startError != null) ...[
            Card(
              key: FlightVisTestKeys.hubStartError,
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _startError!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Two primary enabled actions available immediately (signed in or out).
          FilledButton.icon(
            key: FlightVisTestKeys.hubLiveMap,
            onPressed: _openLiveMap,
            icon: const Icon(Icons.map),
            label: Text(l10n.pilotHubLiveMapButton),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: FlightVisTestKeys.hubStartFlight,
            onPressed: _onTapStartFlight,
            icon: const Icon(Icons.flight_takeoff),
            label: Text(l10n.pilotHubStartFlightButton),
          ),
          if (inPersonalMode) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: FlightVisTestKeys.hubLocalRecordAction,
              onPressed: _onTapRecordLocalOnly,
              icon: const Icon(Icons.save_alt),
              label: Text(l10n.pilotHubLocalRecordAction),
            ),
          ],
          const SizedBox(height: 12),
          _navCard(
            context,
            key: FlightVisTestKeys.hubLocalFlights,
            title: l10n.pilotHubLocalFlightsTitle,
            subtitle: localFlightsSubtitle,
            icon: Icons.history,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => LocalFlightsListScreen(
                  repo: widget.repo,
                  store: _localFlightStore,
                  accountBucket: _accountBucket,
                  tileProvider: widget.tileProvider,
                ),
              ),
            ).then((_) => _refreshLocalFlightCount()),
          ),
          _navCard(
            context,
            key: FlightVisTestKeys.hubCheckIn,
            title: l10n.pilotHubCheckInTitle,
            subtitle: l10n.pilotHubCheckInSubtitle,
            icon: Icons.qr_code_2,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CheckinScreen(
                  repo: widget.repo,
                  pilot: widget.pilot,
                  permissions: widget.permissions,
                  onCheckedIn: () {
                    if (mounted) setState(() {});
                  },
                  onStartFlight: widget.onStartFlight,
                ),
              ),
            ).then((_) {
              if (mounted) setState(() {});
            }),
          ),
          _navCard(
            context,
            key: FlightVisTestKeys.hubFlightDetails,
            title: broadcastTitle,
            subtitle: broadcastSubtitle,
            icon: Icons.cell_tower,
            enabled: canBroadcastCard,
            onTap: canBroadcastCard
                ? () {
                    if (inPersonalMode) {
                      unawaited(_openPersonalFlightStart());
                    } else {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TailPickerScreen(
                            repo: widget.repo,
                            pilot: widget.pilot,
                            permissions: widget.permissions,
                            onFlightStarted: (flight, tail) {
                              Navigator.pop(context);
                              _notifyStartBroadcast(
                                flight.id,
                                tail,
                                flightMode: 'club',
                                startedAtMs: flight.startedAtMs,
                              );
                            },
                          ),
                        ),
                      );
                    }
                  }
                : null,
          ),
          if (loggedIn)
            _navCard(
              context,
              title: l10n.pilotHubPairingTitle,
              subtitle: l10n.pilotHubPairingSubtitle,
              icon: Icons.phonelink_setup,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PairingScreen(
                    repo: widget.repo,
                    onPaired: () => Navigator.pop(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _navCard(
    BuildContext context, {
    Key? key,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback? onTap,
    bool enabled = true,
  }) {
    return Card(
      child: ListTile(
        key: key,
        leading: Icon(icon, color: enabled ? null : Theme.of(context).disabledColor),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }
}

class _LocalFlightStartDialog extends StatefulWidget {
  const _LocalFlightStartDialog({required this.reason});

  final LocalFlightReason reason;

  @override
  State<_LocalFlightStartDialog> createState() =>
      _LocalFlightStartDialogState();
}

class _LocalFlightStartDialogState extends State<_LocalFlightStartDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return AlertDialog(
      key: FlightVisTestKeys.localFlightStartDialog,
      title: Text(l10n.localFlightStartTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.reason == LocalFlightReason.noClubCheckin
                  ? l10n.localFlightNoClubNote
                  : l10n.localFlightOfflineNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: FlightVisTestKeys.localFlightTailField,
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              maxLength: LocalFlight.maxTailLength,
              inputFormatters: [
                _UpperCaseTailFormatter(),
              ],
              decoration: InputDecoration(
                labelText: l10n.localFlightTailLabel,
                hintText: l10n.localFlightTailHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: FlightVisTestKeys.localFlightConfirmStart,
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l10n.pilotStart),
        ),
      ],
    );
  }
}

class _UpperCaseTailFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cleaned =
        newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    final truncated = cleaned.length <= LocalFlight.maxTailLength
        ? cleaned
        : cleaned.substring(0, LocalFlight.maxTailLength);
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}
