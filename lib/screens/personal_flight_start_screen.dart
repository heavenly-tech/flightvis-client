import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/flight_vis_client.dart';
import '../ci_test_keys.dart';
import '../l10n/api_errors.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../services/flight_permissions.dart';
import '../services/flight_start_mode.dart';
import '../widgets/permission_warning_card.dart';
import '../widgets/trail_length_chips.dart';

/// Club-less / "Piloto público" flight start screen.
///
/// Starts a broadcast flight via `POST /api/flights {mode: "personal", tail,
/// visibility}` using the account's personal device token (lazily registered
/// via `POST /api/account/devices {mode: "personal"}` if absent). Requires no
/// club check-in, restricts visibility to `private` / `public` (never `club`),
/// and hides/blocks `public` until `email_verified` is true.
class PersonalFlightStartScreen extends StatefulWidget {
  const PersonalFlightStartScreen({
    super.key,
    required this.repo,
    required this.onFlightStarted,
    this.pilot,
    this.permissions,
    this.initialTail,
  });

  final AppRepository repo;
  final void Function(StartFlightResult flight, String tail) onFlightStarted;
  final PilotProfile? pilot;
  final FlightPermissionsClient? permissions;
  final String? initialTail;

  @override
  State<PersonalFlightStartScreen> createState() =>
      _PersonalFlightStartScreenState();
}

class _PersonalFlightStartScreenState extends State<PersonalFlightStartScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _tailController;
  String _visibility = 'private';
  bool _showPilotNamePublic = false;
  int? _trailMinutes;
  bool _busy = false;
  String? _error;
  FlightPermissionStatus? _permissionStatus;

  FlightPermissionsClient get _permissions =>
      widget.permissions ?? FlightPermissions.instance;

  bool get _allowPublicVisibility => widget.pilot?.emailVerified ?? false;

  String? get _normalizedTail => normalizePersonalTail(_tailController.text);

  @override
  void initState() {
    super.initState();
    _tailController = TextEditingController(text: widget.initialTail ?? '');
    if (_allowPublicVisibility) {
      _visibility = 'public';
    }
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tailController.dispose();
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

  Future<void> _start() async {
    final l10n = context.pilotL10n;
    final tail = _normalizedTail;
    if (tail == null) {
      setState(() => _error = l10n.personalFlightTailRequired);
      return;
    }

    final permStatus = await _permissions.check();
    if (!permStatus.fineLocationGranted) {
      final granted = await _permissions.requestFineLocation();
      final rechecked = await _permissions.check();
      if (mounted) setState(() => _permissionStatus = rechecked);
      if (!granted && !rechecked.fineLocationGranted) {
        if (mounted) {
          setState(() => _error = l10n.permFineRequiredToStart);
        }
        return;
      }
    }

    setState(() {
      _error = null;
      _busy = true;
    });

    final effectiveVisibility =
        (_visibility == 'public' && !_allowPublicVisibility)
            ? 'private'
            : _visibility;
    final showPilotNamePublic =
        effectiveVisibility == 'public' && _showPilotNamePublic;

    try {
      final personalToken = await widget.repo.ensurePersonalDeviceRegistered();
      final result = await widget.repo.client.startFlight(
        mode: 'personal',
        tail: tail,
        visibility: effectiveVisibility,
        showPilotNamePublic: showPilotNamePublic,
        trailMinutes: _trailMinutes,
        sendTrail: _trailMinutes != null,
        deviceToken: personalToken,
      );
      final effectiveTrail =
          result.hasTrailMinutes ? result.trailMinutes : _trailMinutes;
      await widget.repo.prefs.setActiveFlightTrailMinutes(effectiveTrail);
      if (mounted) {
        setState(() => _busy = false);
        widget.onFlightStarted(result, tail);
      }
    } on FlightVisException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = localizeApiException(context.pilotL10n, e);
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = context.pilotL10n.errorGeneric;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final effectiveVisibility =
        (_visibility == 'public' && !_allowPublicVisibility)
            ? 'private'
            : _visibility;

    return Scaffold(
      key: FlightVisTestKeys.personalFlightScreen,
      appBar: AppBar(title: Text(l10n.personalFlightTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.personalFlightIntro, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (_permissionStatus != null &&
                _permissionStatus!.hasTrackingPermissionGaps) ...[
              PermissionWarningCard(
                status: _permissionStatus!,
                permissions: widget.permissions,
                onChanged: _refreshPermissions,
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: FlightVisTestKeys.personalFlightTailField,
              controller: _tailController,
              textCapitalization: TextCapitalization.characters,
              maxLength: 16,
              inputFormatters: [_PersonalTailInputFormatter()],
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: l10n.pilotTailLabel,
                hintText: l10n.personalFlightTailHint,
                helperText: l10n.personalFlightTailHelper,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: effectiveVisibility,
              decoration: InputDecoration(
                labelText: l10n.pilotVisibilityLabel,
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'private',
                  child: Text(l10n.pilotVisibilityPrivate),
                ),
                if (_allowPublicVisibility)
                  DropdownMenuItem(
                    value: 'public',
                    child: Text(l10n.pilotVisibilityPublic),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _visibility = v ?? 'private';
                        if (_visibility != 'public') {
                          _showPilotNamePublic = false;
                        }
                      }),
            ),
            if (!_allowPublicVisibility) ...[
              const SizedBox(height: 6),
              Text(
                l10n.pilotPublicRequiresVerifiedEmail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (effectiveVisibility == 'public')
              SwitchListTile(
                title: Text(l10n.pilotShowPilotNamePublic),
                value: _showPilotNamePublic,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _showPilotNamePublic = v),
              ),
            const SizedBox(height: 16),
            TrailLengthChips(
              selectedMinutes: _trailMinutes,
              clubDefaultMinutes: 5,
              enabled: !_busy,
              onSelected: (minutes) => setState(() => _trailMinutes = minutes),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              key: FlightVisTestKeys.personalFlightStart,
              onPressed: !_busy ? _start : null,
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.pilotStart),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonalTailInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cleaned =
        newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9-]'), '');
    final truncated =
        cleaned.length <= 16 ? cleaned : cleaned.substring(0, 16);
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}
