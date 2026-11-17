import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../services/app_repository.dart';
import '../state/checkin_gate.dart';
import 'qr_scan_screen.dart';

class CheckinScreen extends StatefulWidget {
  const CheckinScreen({super.key, required this.repo, required this.onCheckedIn});

  final AppRepository repo;
  final VoidCallback onCheckedIn;

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen> {
  String? _error;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  CheckinGate get _gate => CheckinGate(
        expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  Future<void> _submitToken(String token) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repo.client.checkin(token);
      final expires = CheckinGate.defaultExpiresAtMs(
        DateTime.now().millisecondsSinceEpoch,
      );
      await widget.repo.prefs.setCheckinExpiresAtMs(expires);
      if (mounted) widget.onCheckedIn();
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = _gate;
    final remaining = gate.remaining();
    return Scaffold(
      appBar: AppBar(title: const Text('Club check-in')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Scan the rotating QR on the club screen (/club/screen). Tokens rotate every 30 seconds.',
            ),
            if (gate.canStartFlight && remaining != null) ...[
              const SizedBox(height: 16),
              Text(
                'Check-in valid for ${remaining.inMinutes}m ${remaining.inSeconds % 60}s (about ${AppConfig.defaultCheckinValidMinutes} min).',
                style: const TextStyle(color: Colors.green),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: widget.onCheckedIn, child: const Text('Continue')),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QrScanScreen(
                            title: 'Scan check-in QR',
                            onScanned: (_) {},
                          ),
                        ),
                      ).then((value) {
                        if (value is String) _submitToken(value);
                      });
                    },
              icon: const Icon(Icons.qr_code_scanner),
              label: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Scan check-in QR'),
            ),
          ],
        ),
      ),
    );
  }
}