import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../state/checkin_gate.dart';

class TailPickerScreen extends StatefulWidget {
  const TailPickerScreen({
    super.key,
    required this.repo,
    required this.onFlightStarted,
  });

  final AppRepository repo;
  final void Function(StartFlightResult flight, String tail) onFlightStarted;

  @override
  State<TailPickerScreen> createState() => _TailPickerScreenState();
}

class _TailPickerScreenState extends State<TailPickerScreen> {
  List<TailOption> _tails = [];
  String? _selectedTail;
  String _visibility = 'club';
  bool _showPilotNamePublic = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tails = await widget.repo.client.tails();
      setState(() {
        _tails = tails;
        _selectedTail = tails.isNotEmpty ? tails.first.tail : null;
        _loading = false;
      });
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _start() async {
    final l10n = context.pilotL10n;
    final gate = CheckinGate(
      expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final blocked = checkinBlockMessage(l10n, gate.startBlock());
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    final tail = _selectedTail;
    if (tail == null) {
      setState(() => _error = l10n.pilotSelectTail);
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final result = await widget.repo.client.startFlight(
        tail: tail,
        visibility: _visibility,
        showPilotNamePublic: _showPilotNamePublic,
      );
      if (mounted) widget.onFlightStarted(result, tail);
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final gate = CheckinGate(
      expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final blockMsg = checkinBlockMessage(l10n, gate.startBlock());
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pilotFlightDetailsTitle)),
      body: _loading && _tails.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!gate.canStartFlight && blockMsg != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(blockMsg),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedTail,
                    decoration: InputDecoration(
                      labelText: l10n.pilotTailLabel,
                      border: const OutlineInputBorder(),
                    ),
                    items: _tails
                        .map((t) => DropdownMenuItem(
                              value: t.tail,
                              child: Text(l10n.pilotTailTypeFormat(t.tail, t.typeCode)),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedTail = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _visibility,
                    decoration: InputDecoration(
                      labelText: l10n.pilotVisibilityLabel,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(value: 'private', child: Text(l10n.pilotVisibilityPrivate)),
                      DropdownMenuItem(value: 'club', child: Text(l10n.pilotVisibilityClub)),
                      DropdownMenuItem(value: 'public', child: Text(l10n.pilotVisibilityPublic)),
                    ],
                    onChanged: (v) => setState(() => _visibility = v ?? 'club'),
                  ),
                  SwitchListTile(
                    title: Text(l10n.pilotShowPilotNamePublic),
                    value: _showPilotNamePublic,
                    onChanged: (v) => setState(() => _showPilotNamePublic = v),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: gate.canStartFlight && !_loading ? _start : null,
                    child: Text(l10n.pilotStart),
                  ),
                ],
              ),
            ),
    );
  }
}