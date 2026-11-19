import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'tracking_lifecycle.dart';

/// Latest SDK log [LogEntry.time] (oldest-first list).
int? newestLogTimestampMs(List<LogEntry> logs) {
  if (logs.isEmpty) return null;
  var max = logs.first.time;
  for (var i = 1; i < logs.length; i++) {
    final t = logs[i].time;
    if (t > max) max = t;
  }
  return max;
}

/// Entries strictly after [afterMs] (handles SDK 5k-line rotation vs index cursors).
List<LogEntry> logEntriesAfter(List<LogEntry> logs, int? afterMs) {
  if (afterMs == null) return List<LogEntry>.from(logs);
  return logs.where((e) => e.time > afterMs).toList(growable: false);
}

bool ingestStopInEntries(Iterable<LogEntry> entries) =>
    entries.any((e) => ingestLogRequiresStop(e.message));