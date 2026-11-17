import 'package:flutter/material.dart';

import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import 'checkin_screen.dart';
import 'hidden_settings_screen.dart';
import 'pairing_screen.dart';
import 'tail_picker_screen.dart';

class HomeHubScreen extends StatefulWidget {
  const HomeHubScreen({
    super.key,
    required this.repo,
    required this.pilotName,
    required this.onStartFlight,
    required this.onLogout,
  });

  final AppRepository repo;
  final String pilotName;
  final void Function(String flightId, String tailLabel) onStartFlight;
  final VoidCallback onLogout;

  @override
  State<HomeHubScreen> createState() => _HomeHubScreenState();
}

class _HomeHubScreenState extends State<HomeHubScreen> {
  int _secretTaps = 0;

  void _openHidden() {
    _secretTaps++;
    if (_secretTaps >= 7) {
      _secretTaps = 0;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HiddenSettingsScreen(repo: widget.repo),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _openHidden,
          child: const Text('flight_vis'),
        ),
        actions: [
          IconButton(
            onPressed: () async {
              await widget.repo.client.logout();
              await widget.repo.secure.clearAll();
              widget.onLogout();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.pilotHubSignedInAs(widget.pilotName)),
          const SizedBox(height: 16),
          _navCard(
            context,
            title: l10n.pilotHubCheckInTitle,
            subtitle: l10n.pilotHubCheckInSubtitle,
            icon: Icons.qr_code_2,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CheckinScreen(
                  repo: widget.repo,
                  onCheckedIn: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
          _navCard(
            context,
            title: l10n.pilotHubFlightTitle,
            subtitle: l10n.pilotHubFlightSubtitle,
            icon: Icons.flight_takeoff,
            onTap: () => Navigator.push(
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
            ),
          ),
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
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}