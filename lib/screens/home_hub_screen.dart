import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../dev/dev_tools_gate.dart';
import '../l10n/pilot_l10n.dart';
import '../util/checkin_expiry_format.dart';
import '../services/app_repository.dart';
import '../state/checkin_gate.dart';
import 'checkin_screen.dart';
import 'hidden_settings_screen.dart';
import 'pairing_screen.dart';
import 'tail_picker_screen.dart';
import '../widgets/language_picker_sheet.dart';
import '../ci_test_keys.dart';

class HomeHubScreen extends StatefulWidget {
  const HomeHubScreen({
    super.key,
    required this.repo,
    required this.onStartFlight,
    required this.onRequestLogin,
    required this.onLogout,
    this.pilot,
    this.onLocaleChanged,
  });

  final AppRepository repo;
  final PilotProfile? pilot;
  final void Function(String flightId, String tailLabel) onStartFlight;
  final VoidCallback onRequestLogin;
  final VoidCallback onLogout;
  final VoidCallback? onLocaleChanged;

  @override
  State<HomeHubScreen> createState() => _HomeHubScreenState();
}

class _HomeHubScreenState extends State<HomeHubScreen> {
  int _secretTaps = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (!AppConfig.screenshotTest) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  CheckinGate get _gate => CheckinGate(
        expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

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
    final name = widget.repo.prefs.activeClubName() ?? widget.repo.prefs.activeClubSlug();
    if (name != null && name.isNotEmpty) {
      return l10n.pilotHubActiveClub(name);
    }
    return l10n.pilotHubNoClubYet;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final gate = _gate;
    final pilot = widget.pilot;
    final loggedIn = pilot != null && pilot.isApproved;
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
            loggedIn ? l10n.pilotHubSignedInAs(pilot.name) : l10n.pilotHubGuestMode,
          ),
          const SizedBox(height: 4),
          Text(_clubLine(context), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (_checkinBanner(context) != null) ...[
            _checkinBanner(context)!,
            const SizedBox(height: 12),
          ],
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
            title: l10n.pilotHubFlightTitle,
            subtitle: gate.canStartFlight
                ? l10n.pilotHubFlightSubtitle
                : l10n.pilotHubFlightLockedSubtitle,
            icon: Icons.flight_takeoff,
            enabled: gate.canStartFlight,
            onTap: gate.canStartFlight
                ? () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TailPickerScreen(
                          repo: widget.repo,
                          onFlightStarted: (flight, tail) {
                            Navigator.pop(context);
                            widget.onStartFlight(flight.id, tail);
                          },
                        ),
                      ),
                    )
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