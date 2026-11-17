import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

import '../l10n/pilot_l10n.dart';

class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.permLegacyTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.permLegacyIntro, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            _tile(
              context,
              icon: Icons.my_location,
              title: l10n.permLegacyLocationTitle,
              subtitle: l10n.permLegacyLocationSubtitle,
              onOpen: () => AppSettings.openAppSettings(type: AppSettingsType.location),
            ),
            _tile(
              context,
              icon: Icons.battery_charging_full,
              title: l10n.permLegacyBatteryTitle,
              subtitle: l10n.permLegacyBatterySubtitle,
              onOpen: () => AppSettings.openAppSettings(type: AppSettingsType.batteryOptimization),
            ),
            const Spacer(),
            FilledButton(onPressed: onContinue, child: Text(l10n.permContinue)),
          ],
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onOpen,
  }) {
    final l10n = context.pilotL10n;
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: TextButton(onPressed: onOpen, child: Text(l10n.permOpenSettings)),
      ),
    );
  }
}