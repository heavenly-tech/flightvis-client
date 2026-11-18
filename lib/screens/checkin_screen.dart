import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../app_config.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../state/checkin_gate.dart';
import '../util/checkin_expiry_format.dart';
import '../util/flight_deep_link.dart';
import 'qr_scan_screen.dart';
import '../ci_test_keys.dart';

class CheckinScreen extends StatefulWidget {
  const CheckinScreen({
    super.key,
    required this.repo,
    required this.onCheckedIn,
    this.initialScan,
    this.initialClubSlug,
    this.onLoginRequired,
  });

  final AppRepository repo;
  final VoidCallback onCheckedIn;
  final VoidCallback? onLoginRequired;
  final String? initialScan;
  final String? initialClubSlug;

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
    if (!AppConfig.screenshotTest) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    if (widget.initialScan != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _submitRaw(widget.initialScan!);
      });
    }
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

  void _continueAfterCheckin() {
    if (!mounted) return;
    Navigator.maybePop(context);
    widget.onCheckedIn();
  }

  String _successText(AppLocalizations l10n) {
    final expiresMs = widget.repo.prefs.checkinExpiresAtMs();
    if (expiresMs == null) return l10n.pilotCheckInSuccess;
    final until = CheckinExpiryFormat.formatFromEpochMs(expiresMs);
    return l10n.pilotCheckInValidUntil(until);
  }

  Future<void> _submitRaw(String raw) async {
    final payload = FlightDeepLink.parseCheckinScan(raw);
    if (payload == null) {
      setState(() => _error = context.pilotL10n.pilotCheckInInvalidCode);
      return;
    }
    await _submitToken(payload.token, clubSlug: payload.clubSlug ?? widget.initialClubSlug);
  }

  Future<void> _submitToken(String token, {String? clubSlug}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.repo.syncClubFromPrefs();
      final result = await widget.repo.client.checkin(token, clubSlug: clubSlug);
      final expiresMs = result.expiresAtEpochMs();
      await widget.repo.prefs.setCheckinExpiresAtMs(expiresMs);
      await widget.repo.applyCheckinClub(result, fallbackSlug: clubSlug);
      if (mounted) {
        setState(() {
          _busy = false;
          _justCheckedIn = true;
        });
      }
    } on FlightVisException catch (e) {
      if (e.statusCode == 401 && widget.onLoginRequired != null) {
        await widget.repo.prefs.setPendingCheckin(
          slug: clubSlug ?? widget.repo.prefs.pendingCheckinSlug(),
          token: token,
        );
        widget.onLoginRequired!();
      }
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
    return Scaffold(
      key: FlightVisTestKeys.checkinScreen,
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
                _successText(l10n),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: FlightVisTestKeys.checkinContinue,
                onPressed: _continueAfterCheckin,
                child: Text(l10n.pilotContinue),
              ),
            ],
            if (!_justCheckedIn && gate.canStartFlight && gate.expiresAtMs != null) ...[
              const SizedBox(height: 16),
              Text(
                l10n.pilotCheckInValidUntil(
                  CheckinExpiryFormat.formatFromEpochMs(gate.expiresAtMs!),
                ),
                style: const TextStyle(color: Colors.green),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: FlightVisTestKeys.checkinContinue,
                onPressed: _continueAfterCheckin,
                child: Text(l10n.pilotContinue),
              ),
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
              onPressed: _busy ? null : () => _submitRaw(_pasteController.text),
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
                        if (value is String) _submitRaw(value);
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