import 'package:flutter/material.dart';

import '../ci_test_keys.dart';
import '../l10n/pilot_l10n.dart';
import '../services/flight_permissions.dart';

class PermissionWarningCard extends StatelessWidget {
  const PermissionWarningCard({
    super.key,
    required this.status,
    this.onChanged,
    this.permissions,
  });

  final FlightPermissionStatus status;
  final VoidCallback? onChanged;
  final FlightPermissionsClient? permissions;

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final gaps = status.gaps();
    if (gaps.isEmpty) return const SizedBox.shrink();
    final permClient = permissions ?? FlightPermissions.instance;

    String label(PermissionGap gap) {
      return switch (gap) {
        PermissionGap.backgroundLocation => l10n.permWarningBackground,
        PermissionGap.fineLocation => l10n.permFineBody,
        PermissionGap.notifications => l10n.permNotifBody,
        PermissionGap.battery => l10n.permBatteryBody,
      };
    }

    return Card(
      key: FlightVisTestKeys.permissionWarningCard,
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.permWarningTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final gap in gaps) ...[
              Text('• ${label(gap)}'),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () async {
                    await permClient.openGapSettings(gap);
                    onChanged?.call();
                  },
                  child: Text(l10n.permWarningFix),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
