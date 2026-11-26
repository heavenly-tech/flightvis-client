import 'package:flutter/material.dart';

import '../ci_test_keys.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../services/flight_permissions.dart';

enum _PermStep { intro, fine, background, notifications, battery, done }

class PermissionsOnboardingScreen extends StatefulWidget {
  const PermissionsOnboardingScreen({
    super.key,
    required this.repo,
    required this.onComplete,
    this.permissions,
  });

  final AppRepository repo;
  final VoidCallback onComplete;
  final FlightPermissionsClient? permissions;

  @override
  State<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState
    extends State<PermissionsOnboardingScreen> with WidgetsBindingObserver {
  _PermStep _step = _PermStep.intro;
  bool _busy = false;
  bool _denied = false;
  final Set<PermissionGap> _missingGaps = {};

  FlightPermissionsClient get _permissions =>
      widget.permissions ?? FlightPermissions.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _denied && !_busy) {
      _recheckCurrentStep();
    }
  }

  PermissionGap? _gapForStep(_PermStep step) {
    return switch (step) {
      _PermStep.fine => PermissionGap.fineLocation,
      _PermStep.background => PermissionGap.backgroundLocation,
      _PermStep.notifications => PermissionGap.notifications,
      _PermStep.battery => PermissionGap.battery,
      _PermStep.intro || _PermStep.done => null,
    };
  }

  _PermStep _nextStep(_PermStep step) {
    return switch (step) {
      _PermStep.intro => _PermStep.fine,
      _PermStep.fine => _PermStep.background,
      _PermStep.background => _PermStep.notifications,
      _PermStep.notifications => _PermStep.battery,
      _PermStep.battery => _PermStep.done,
      _PermStep.done => _PermStep.done,
    };
  }

  Future<void> _recheckCurrentStep() async {
    final gap = _gapForStep(_step);
    if (gap == null) return;
    final status = await _permissions.check();
    if (!mounted) return;
    final granted = switch (gap) {
      PermissionGap.fineLocation => status.fineLocationGranted,
      PermissionGap.backgroundLocation => status.backgroundLocationGranted,
      PermissionGap.notifications => status.notificationsGranted,
      PermissionGap.battery => status.batteryUnrestricted,
    };
    if (granted) {
      _missingGaps.remove(gap);
      setState(() {
        _denied = false;
        _step = _nextStep(_step);
      });
    }
  }

  void _handlePermissionResult(PermissionGap gap, bool granted) {
    if (!mounted) return;
    if (granted) {
      _missingGaps.remove(gap);
      setState(() {
        _denied = false;
        _step = _nextStep(_step);
      });
    } else {
      setState(() {
        _denied = true;
      });
    }
  }

  Future<void> _advance() async {
    setState(() => _busy = true);
    try {
      switch (_step) {
        case _PermStep.intro:
          if (mounted) {
            setState(() {
              _denied = false;
              _step = _PermStep.fine;
            });
          }
        case _PermStep.fine:
          final granted = await _permissions.requestFineLocation();
          _handlePermissionResult(PermissionGap.fineLocation, granted);
        case _PermStep.background:
          final granted = await _permissions.requestBackgroundLocation();
          _handlePermissionResult(PermissionGap.backgroundLocation, granted);
        case _PermStep.notifications:
          final granted = await _permissions.requestNotifications();
          _handlePermissionResult(PermissionGap.notifications, granted);
        case _PermStep.battery:
          final granted = await _permissions.requestBatteryExemption();
          _handlePermissionResult(PermissionGap.battery, granted);
        case _PermStep.done:
          await widget.repo.prefs.setPermissionsOnboardingComplete(true);
          if (mounted) widget.onComplete();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    await _permissions.openSettings();
  }

  void _skipCurrentStep() {
    final gap = _gapForStep(_step);
    if (gap != null) {
      _missingGaps.add(gap);
    }
    setState(() {
      _denied = false;
      _step = _nextStep(_step);
    });
  }

  String _missingListText(AppLocalizations l10n) {
    final ordered = [
      if (_missingGaps.contains(PermissionGap.fineLocation)) l10n.permFineTitle,
      if (_missingGaps.contains(PermissionGap.backgroundLocation))
        l10n.permGapBackgroundName,
      if (_missingGaps.contains(PermissionGap.notifications))
        l10n.permNotifTitle,
      if (_missingGaps.contains(PermissionGap.battery)) l10n.permBatteryTitle,
    ];
    return ordered.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final stepNumber = _step.index + 1;
    final totalSteps = _PermStep.values.length;

    final (title, body, action) = switch (_step) {
      _PermStep.intro => (
          l10n.permOnboardingTitle,
          l10n.permIntroBody,
          l10n.permContinue,
        ),
      _PermStep.fine => (
          l10n.permFineTitle,
          l10n.permFineBody,
          l10n.permFineAction,
        ),
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
      _PermStep.done => _missingGaps.isEmpty
          ? (l10n.permDoneTitle, l10n.permDoneBody, l10n.permFinish)
          : (
              l10n.permDoneMissingTitle,
              l10n.permDoneMissingBody(_missingListText(l10n)),
              l10n.permFinish,
            ),
    };

    return Scaffold(
      key: FlightVisTestKeys.permissionsScreen,
      appBar: AppBar(title: Text(l10n.permOnboardingTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.permStepIndicator(stepNumber, totalSteps),
                key: FlightVisTestKeys.permissionsStepIndicator,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: stepNumber / totalSteps),
              const SizedBox(height: 20),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      Text(
                        body,
                        style: const TextStyle(fontSize: 16, height: 1.45),
                      ),
                      if (_denied) ...[
                        const SizedBox(height: 20),
                        Card(
                          key: FlightVisTestKeys.permissionsDeniedMessage,
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    l10n.permDeniedInline,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onErrorContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
              if (_denied) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  key: FlightVisTestKeys.permissionsOpenSettings,
                  onPressed: _busy ? null : _openSettings,
                  child: Text(l10n.permOpenAppSettings),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: FlightVisTestKeys.permissionsSkip,
                  onPressed: _busy ? null : _skipCurrentStep,
                  child: Text(l10n.permContinueAnyway),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
