import 'package:flutter/material.dart';

import '../ci_test_keys.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';
import '../services/flight_permissions.dart';
import '../services/permission_fix_flow.dart';

/// Warning card shown when one or more tracking permissions are missing.
///
/// Lists every missing gap and exposes a single primary "Corregir" button that
/// walks through gaps in order:
/// `fineLocation -> backgroundLocation -> notifications -> battery`.
class PermissionWarningCard extends StatefulWidget {
  const PermissionWarningCard({
    super.key,
    required this.status,
    this.onChanged,
    this.permissions,
    this.initialHintGap,
  });

  final FlightPermissionStatus status;
  final VoidCallback? onChanged;
  final FlightPermissionsClient? permissions;

  /// Optional pre-seeded OEM hint gap for deterministic widget/golden tests.
  final PermissionGap? initialHintGap;

  @override
  State<PermissionWarningCard> createState() => _PermissionWarningCardState();
}

class _PermissionWarningCardState extends State<PermissionWarningCard> {
  late PermissionFixFlow _flow;
  bool _busy = false;
  PermissionGap? _hintOverride;

  FlightPermissionsClient get _permClient =>
      widget.permissions ?? FlightPermissions.instance;

  @override
  void initState() {
    super.initState();
    _flow = PermissionFixFlow(client: _permClient);
    _hintOverride = widget.initialHintGap;
  }

  @override
  void didUpdateWidget(covariant PermissionWarningCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.permissions != widget.permissions) {
      _flow = PermissionFixFlow(client: _permClient);
    }
    _flow.onStatusChecked(widget.status);
    if (_hintOverride != null && widget.status.isGapGranted(_hintOverride!)) {
      _hintOverride = null;
    }
  }

  String _gapLabel(AppLocalizations l10n, PermissionGap gap) {
    return switch (gap) {
      PermissionGap.fineLocation => l10n.permFineBody,
      PermissionGap.backgroundLocation => l10n.permWarningBackground,
      PermissionGap.notifications => l10n.permNotifBody,
      PermissionGap.battery => l10n.permBatteryBody,
    };
  }

  String _oemHint(AppLocalizations l10n, PermissionGap gap) {
    return switch (gap) {
      PermissionGap.battery => l10n.permOemHintBattery,
      PermissionGap.backgroundLocation => l10n.permOemHintBackground,
      PermissionGap.notifications => l10n.permOemHintNotifications,
      PermissionGap.fineLocation => l10n.permOemHintFine,
    };
  }

  Future<void> _fixNext() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _hintOverride = null;
    });
    try {
      await _flow.fixNext(widget.status);
      widget.onChanged?.call();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    final gaps = widget.status.gaps();
    if (gaps.isEmpty) return const SizedBox.shrink();

    final hintGap = _flow.stuckGap ?? _hintOverride;
    final showHint = hintGap != null && gaps.contains(hintGap);

    return Card(
      key: FlightVisTestKeys.permissionWarningCard,
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.permWarningTitle,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 8),
            for (final gap in gaps) ...[
              Text(
                '• ${_gapLabel(l10n, gap)}',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
              const SizedBox(height: 4),
            ],
            if (showHint) ...[
              const SizedBox(height: 4),
              Text(
                _oemHint(l10n, hintGap),
                key: FlightVisTestKeys.permissionWarningHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                key: FlightVisTestKeys.permissionWarningFix,
                onPressed: _busy ? null : _fixNext,
                child: Text(l10n.permWarningFix),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
