import 'package:flutter/material.dart';

import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../services/flight_permissions.dart';
import '../ci_test_keys.dart';

enum _PermStep { intro, fine, background, notifications, battery, done }

class PermissionsOnboardingScreen extends StatefulWidget {
  const PermissionsOnboardingScreen({
    super.key,
    required this.repo,
    required this.onComplete,
  });

  final AppRepository repo;
  final VoidCallback onComplete;

  @override
  State<PermissionsOnboardingScreen> createState() => _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState extends State<PermissionsOnboardingScreen> {
  _PermStep _step = _PermStep.intro;
  bool _busy = false;

  Future<void> _advance() async {
    setState(() => _busy = true);
    try {
      switch (_step) {
        case _PermStep.intro:
          setState(() => _step = _PermStep.fine);
        case _PermStep.fine:
          await FlightPermissions.requestFineLocation();
          if (mounted) setState(() => _step = _PermStep.background);
        case _PermStep.background:
          await FlightPermissions.requestBackgroundLocation();
          if (mounted) setState(() => _step = _PermStep.notifications);
        case _PermStep.notifications:
          await FlightPermissions.requestNotifications();
          if (mounted) setState(() => _step = _PermStep.battery);
        case _PermStep.battery:
          await FlightPermissions.requestBatteryExemption();
          if (mounted) setState(() => _step = _PermStep.done);
        case _PermStep.done:
          await widget.repo.prefs.setPermissionsOnboardingComplete(true);
          if (mounted) widget.onComplete();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final (title, body, action) = switch (_step) {
      _PermStep.intro => (
          l10n.permOnboardingTitle,
          l10n.permIntroBody,
          l10n.permContinue,
        ),
      _PermStep.fine => (l10n.permFineTitle, l10n.permFineBody, l10n.permFineAction),
      _PermStep.background => (
          l10n.permBackgroundTitle,
          l10n.permBackgroundBody,
          l10n.permBackgroundAction,
        ),
      _PermStep.notifications => (
          l10n.permNotifTitle,
          l10n.permNotifBody,
          l10n.permNotifAction,
        ),
      _PermStep.battery => (
          l10n.permBatteryTitle,
          l10n.permBatteryBody,
          l10n.permBatteryAction,
        ),
      _PermStep.done => (l10n.permOnboardingTitle, l10n.permIntroBody, l10n.permFinish),
    };

    return Scaffold(
      key: FlightVisTestKeys.permissionsScreen,
      appBar: AppBar(title: Text(l10n.permOnboardingTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text(body, style: const TextStyle(fontSize: 16, height: 1.45)),
            const Spacer(),
            FilledButton(
              key: FlightVisTestKeys.permissionsPrimary,
              onPressed: _busy ? null : _advance,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(action),
            ),
          ],
        ),
      ),
    );
  }
}