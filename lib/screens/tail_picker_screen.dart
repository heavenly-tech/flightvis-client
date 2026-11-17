import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
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
    final gate = CheckinGate(
      expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final blocked = gate.startBlockedReason();
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    final tail = _selectedTail;
    if (tail == null) {
      setState(() => _error = 'Select a tail.');
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
      await widget.repo.prefs.setCheckinExpiresAtMs(null);
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
    final gate = CheckinGate(
      expiresAtMs: widget.repo.prefs.checkinExpiresAtMs(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Start flight')),
      body: _loading && _tails.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!gate.canStartFlight)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(gate.startBlockedReason() ?? 'Check-in required'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedTail,
                    decoration: const InputDecoration(
                      labelText: 'Tail',
                      border: OutlineInputBorder(),
                    ),
                    items: _tails
                        .map((t) => DropdownMenuItem(
                              value: t.tail,
                              child: Text('${t.tail} (${t.typeCode})'),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedTail = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _visibility,
                    decoration: const InputDecoration(
                      labelText: 'Visibility',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'private', child: Text('Private')),
                      DropdownMenuItem(value: 'club', child: Text('Club')),
                      DropdownMenuItem(value: 'public', child: Text('Public')),
                    ],
                    onChanged: (v) => setState(() => _visibility = v ?? 'club'),
                  ),
                  SwitchListTile(
                    title: const Text('Show pilot name on public map'),
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
                    child: const Text('Start tracking'),
                  ),
                ],
              ),
            ),
    );
  }
}