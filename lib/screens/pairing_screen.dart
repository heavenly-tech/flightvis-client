import 'package:flutter/material.dart';

import '../l10n/pilot_l10n.dart';
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
    final l10n = context.pilotL10n;
    if (token.length < 32) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.pilotDeviceTokenTooShort)),
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
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pilotPairingTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.pilotPairingIntro),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.push<String?>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => QrScanScreen(
                      title: l10n.pilotScanPairingQr,
                      onScanned: (_) {},
                    ),
                  ),
                ).then((value) {
                  if (value != null) _saveToken(value);
                });
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(l10n.pilotScanPairingQr),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pasteController,
              decoration: InputDecoration(
                labelText: l10n.pilotPasteDeviceToken,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _saveToken(_pasteController.text),
              child: Text(l10n.pilotSaveDeviceToken),
            ),
          ],
        ),
      ),
    );
  }
}