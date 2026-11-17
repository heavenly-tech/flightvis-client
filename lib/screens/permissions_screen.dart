import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'flight_vis needs location and battery settings so your track continues in the background during a flight.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            _tile(
              context,
              icon: Icons.my_location,
              title: 'Location — Allow all the time',
              subtitle: 'Required for continuous GPS while the screen is off.',
              onOpen: () => AppSettings.openAppSettings(type: AppSettingsType.location),
            ),
            _tile(
              context,
              icon: Icons.battery_charging_full,
              title: 'Unrestricted battery',
              subtitle: 'Disable battery optimizations for this app so Android does not kill tracking.',
              onOpen: () => AppSettings.openAppSettings(type: AppSettingsType.batteryOptimization),
            ),
            const Spacer(),
            FilledButton(onPressed: onContinue, child: const Text('Continue')),
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
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: TextButton(onPressed: onOpen, child: const Text('Open')),
      ),
    );
  }
}