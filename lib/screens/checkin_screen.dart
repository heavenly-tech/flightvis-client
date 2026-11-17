import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';
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
  bool _justCheckedIn = false;
  final _pasteController = TextEditingController();
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
    _pasteController.dispose();
    super.dispose();
  }

  CheckinGate get _gate => CheckinGate(
        expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

  String _countdownText(AppLocalizations l10n) {
    final remaining = _gate.remaining();
    if (remaining == null) {
      return l10n.pilotCheckInSuccess;
    }
    if (remaining <= Duration.zero) {
      return l10n.pilotCheckInExpired;
    }
    return l10n.pilotCheckInValidFor(remaining.inMinutes, remaining.inSeconds % 60);
  }

  Future<void> _submitToken(String token) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.repo.client.checkin(token);
      final expiresMs = result.expiresAtEpochMs();
      await widget.repo.prefs.setCheckinExpiresAtMs(expiresMs);
      if (mounted) {
        setState(() {
          _busy = false;
          _justCheckedIn = true;
        });
      }
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
    final l10n = context.pilotL10n;
    final gate = _gate;
    final remaining = gate.remaining();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pilotCheckInTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.pilotCheckInIntro),
            if (_justCheckedIn) ...[
              const SizedBox(height: 16),
              Text(
                _countdownText(l10n),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: widget.onCheckedIn, child: Text(l10n.pilotContinue)),
            ],
            if (!_justCheckedIn && gate.canStartFlight && remaining != null) ...[
              const SizedBox(height: 16),
              Text(
                l10n.pilotCheckInValidFor(remaining.inMinutes, remaining.inSeconds % 60),
                style: const TextStyle(color: Colors.green),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: widget.onCheckedIn, child: Text(l10n.pilotContinue)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _pasteController,
              decoration: InputDecoration(
                labelText: l10n.pilotPasteCheckInToken,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _submitToken(_pasteController.text),
              child: Text(l10n.pilotSubmitPastedToken),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QrScanScreen(
                            title: l10n.pilotScanCheckInQr,
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
                  : Text(l10n.pilotScanCheckInQr),
            ),
          ],
        ),
      ),
    );
  }
}