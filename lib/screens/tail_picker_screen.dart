import 'dart:async';

import 'package:flutter/material.dart';

import '../api/flight_vis_client.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../state/checkin_gate.dart';
import '../util/tail_format.dart';

const _newTypeSentinel = '__new_type__';

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
  List<AccessRequest> _accessRequests = [];
  String? _selectedTail;
  String _visibility = 'club';
  bool _showPilotNamePublic = false;
  bool _loading = true;
  String? _error;
  String? _accessStatusMessage;
  Timer? _pollTimer;
  final _requestTailController = TextEditingController();
  final _newTypeController = TextEditingController();
  String? _requestTypeCode;
  bool _requestBusy = false;
  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollAccess());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _requestTailController.dispose();
    _newTypeController.dispose();
    super.dispose();
  }

  Set<String> get _knownTypeCodes => {
        ..._tails.map((t) => t.typeCode),
        ..._accessRequests.map((r) => r.typeCode),
        'C172',
        'C152',
      };

  List<String> get _clearedTails => _tails.map((t) => t.tail).toList();

  bool _isPendingOnlyTail(String? tail) {
    if (tail == null) return false;
    if (_clearedTails.contains(tail)) return false;
    return _accessRequests.any((r) => r.tail == tail && r.isPending);
  }

  AccessRequest? _requestForTail(String tail) {
    for (final r in _accessRequests) {
      if (r.tail == tail) return r;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.repo.client.tails(),
        widget.repo.client.accessRequests(),
      ]);
      final tails = results[0] as List<TailOption>;
      final reqs = results[1] as List<AccessRequest>;
      if (!mounted) return;
      setState(() {
        _tails = tails;
        _accessRequests = reqs;
        _selectedTail ??= tails.isNotEmpty ? tails.first.tail : _firstSelectableTail(reqs);
        _requestTypeCode ??= _knownTypeCodes.isNotEmpty ? _knownTypeCodes.first : null;
        _loading = false;
      });
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  String? _firstSelectableTail(List<AccessRequest> reqs) {
    for (final r in reqs) {
      if (r.isPending) return r.tail;
    }
    return null;
  }

  Future<void> _pollAccess() async {
    if (!mounted) return;
    try {
      final reqs = await widget.repo.client.accessRequests();
      final hadPending = _accessRequests.any((r) => r.isPending);
      final prevApproved = _clearedTails.toSet();
      await _applyAccessUpdate(reqs, refreshTails: reqs.any((r) => r.isApproved));
      if (!mounted) return;
      final newlyApproved = _clearedTails.where((t) => !prevApproved.contains(t));
      if (newlyApproved.isNotEmpty) {
        final tail = newlyApproved.first;
        final l10n = context.pilotL10n;
        setState(() {
          _selectedTail = tail;
          _accessStatusMessage = l10n.pilotAccessApproved(tail);
        });
      } else if (hadPending && reqs.any((r) => r.isRejected)) {
        final rejected = reqs.firstWhere((r) => r.isRejected);
        final l10n = context.pilotL10n;
        setState(() {
          _accessStatusMessage = l10n.pilotAccessRejected(
            rejected.tail,
            rejected.rejectReason ?? rejected.status,
          );
        });
      }
    } catch (_) {
      // keep polling quietly on transient errors
    }
  }

  Future<void> _applyAccessUpdate(List<AccessRequest> reqs, {bool refreshTails = false}) async {
    if (refreshTails) {
      final tails = await widget.repo.client.tails();
      if (!mounted) return;
      setState(() {
        _tails = tails;
        _accessRequests = reqs;
      });
      return;
    }
    if (mounted) setState(() => _accessRequests = reqs);
  }

  Future<void> _submitAccessRequest() async {
    final l10n = context.pilotL10n;
    final tail = normalizeChileTail(_requestTailController.text);
    final tailErr = validateChileTail(tail);
    if (tailErr != null) {
      setState(() => _error = l10n.pilotRequestInvalidTail);
      return;
    }
    final typeCode = _requestTypeCode == _newTypeSentinel
        ? _newTypeController.text.trim().toUpperCase()
        : (_requestTypeCode ?? '');
    if (typeCode.isEmpty) {
      setState(() => _error = l10n.pilotRequestEnterType);
      return;
    }
    setState(() {
      _error = null;
      _accessStatusMessage = null;
      _requestBusy = true;
    });
    try {
      await widget.repo.client.createAccessRequest(tail: tail, typeCode: typeCode);
      _requestTailController.clear();
      _newTypeController.clear();
      await _load();
      if (mounted) {
        setState(() {
          _requestBusy = false;
          _selectedTail = tail;
          _accessStatusMessage = l10n.pilotAccessPending(tail);
        });
      }
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _requestBusy = false;
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
    if (_isPendingOnlyTail(_selectedTail)) {
      setState(() => _error = l10n.pilotAccessPendingStartBlocked);
      return;
    }
    final tail = _selectedTail;
    if (tail == null || !_clearedTails.contains(tail)) {
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
      await widget.repo.prefs.setCheckinExpiresAtMs(null);
      if (mounted) widget.onFlightStarted(result, tail);
    } on FlightVisException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Iterable<DropdownMenuItem<String>> _tailMenuItems(AppLocalizations l10n) sync* {
    for (final t in _tails) {
      yield DropdownMenuItem(value: t.tail, child: Text('${t.tail} (${t.typeCode})'));
    }
    for (final r in _accessRequests) {
      if (_clearedTails.contains(r.tail)) continue;
      final label = r.isPending
          ? '${r.tail} (${r.typeCode}) — ${l10n.pilotAccessPending(r.tail).split(' ').first}…'
          : '${r.tail} (${r.typeCode})';
      yield DropdownMenuItem(value: r.tail, child: Text(label));
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
    final pendingTail = _isPendingOnlyTail(_selectedTail);
    final selectedReq = _selectedTail != null ? _requestForTail(_selectedTail!) : null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.pilotFlightDetailsTitle)),
      body: _loading && _tails.isEmpty && _accessRequests.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
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
                  if (_accessStatusMessage != null) ...[
                    const SizedBox(height: 8),
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_accessStatusMessage!),
                      ),
                    ),
                  ],
                  if (selectedReq != null && selectedReq.isRejected) ...[
                    const SizedBox(height: 8),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          l10n.pilotAccessRejected(
                            selectedReq.tail,
                            selectedReq.rejectReason ?? '',
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedTail,
                    decoration: InputDecoration(
                      labelText: l10n.pilotTailLabel,
                      border: const OutlineInputBorder(),
                    ),
                    items: _tailMenuItems(l10n).toList(),
                    onChanged: (v) => setState(() => _selectedTail = v),
                  ),
                  if (pendingTail) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.pilotAccessPendingStartBlocked,
                      style: TextStyle(color: Theme.of(context).colorScheme.secondary),
                    ),
                  ],
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
                  const Divider(height: 32),
                  ExpansionTile(
                    title: Text(l10n.pilotRequestAnotherAircraft),
                    children: [
                      TextField(
                        controller: _requestTailController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: l10n.pilotRequestTailLabel,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: _requestTypeCode ?? _knownTypeCodes.firstOrNull ?? _newTypeSentinel,
                        decoration: InputDecoration(
                          labelText: l10n.pilotRequestTypeLabel,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          ..._knownTypeCodes.map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          ),
                          DropdownMenuItem(
                            value: _newTypeSentinel,
                            child: Text(l10n.pilotRequestNewType),
                          ),
                        ],
                        onChanged: (v) => setState(() => _requestTypeCode = v),
                      ),
                      if (_requestTypeCode == _newTypeSentinel) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _newTypeController,
                          textCapitalization: TextCapitalization.characters,
                          decoration: InputDecoration(
                            labelText: l10n.pilotRequestNewTypeHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _requestBusy ? null : _submitAccessRequest,
                        child: _requestBusy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(l10n.pilotRequestSubmit),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: gate.canStartFlight && !_loading && !pendingTail ? _start : null,
                    child: Text(l10n.pilotStart),
                  ),
                ],
              ),
            ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}