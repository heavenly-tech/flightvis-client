import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/pilot_l10n.dart';

typedef QrScanCallback = void Function(String rawValue);

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, required this.title, required this.onScanned});

  final String title;
  final QrScanCallback onScanned;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  late final MobileScannerController _controller;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.trim().isEmpty) return;
    _scanned = true;
    widget.onScanned(raw.trim());
    if (mounted) Navigator.pop(context, raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: MobileScanner(
        controller: _controller,
        fit: BoxFit.cover,
        onDetect: _onDetect,
        errorBuilder: (context, error) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 72),
              const SizedBox(height: 12),
              Text(l10n.pilotQrCameraUnavailable),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => AppSettings.openAppSettings(type: AppSettingsType.settings),
                child: Text(l10n.pilotQrOpenSettings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}