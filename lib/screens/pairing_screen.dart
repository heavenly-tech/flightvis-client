import 'package:flutter/material.dart';

import '../services/app_repository.dart';
import 'qr_scan_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.repo, required this.onPaired});

  final AppRepository repo;
  final VoidCallback onPaired;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _pasteController = TextEditingController();

  Future<void> _saveToken(String token) async {
    if (token.length < 32) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device token looks too short.')),
        );
      }
      return;
    }
    await widget.repo.persistDeviceToken(token);
    if (mounted) widget.onPaired();
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device pairing')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Pair this phone with your pilot account using the one-time token from the club website (My devices → new device QR).',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.push<String?>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => QrScanScreen(
                      title: 'Scan pairing QR',
                      onScanned: (_) {},
                    ),
                  ),
                ).then((value) {
                  if (value != null) _saveToken(value);
                });
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan pairing QR'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pasteController,
              decoration: const InputDecoration(
                labelText: 'Or paste device token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _saveToken(_pasteController.text),
              child: const Text('Save token'),
            ),
          ],
        ),
      ),
    );
  }
}