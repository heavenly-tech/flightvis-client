import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/flight_vis_client.dart';
import '../storage/fix_upload_queue.dart';

typedef BatchUploadCallback = Future<IngestBatchResult> Function(
  List<QueuedFix> batch, {
  required String flightMode,
});

typedef BackoffClock = DateTime Function();
typedef BackoffRandom = double Function();
typedef BackoffSleep = Future<void> Function(Duration delay);

/// Exponential backoff with full jitter and clamped `Retry-After` minimum-wait
/// floor (L-89: `Retry-After` clamped to `[0, 1 hour]`).
///
/// - Base: 2 seconds
/// - Cap: 5 minutes (300 seconds)
/// - Full jitter: uniform in `[0, min(cap, base * 2^(attempt - 1))]`
/// - `Retry-After` (integer seconds or HTTP-date, clamped to `[0, 1 hour]`)
///   takes precedence as the minimum wait (`max(jitteredBackoff, retryAfter)`).
Duration computeUploadBackoff({
  required int attempt,
  required BackoffRandom randomDouble,
  Duration? retryAfter,
  Duration baseDelay = FixUploadWorker.baseBackoff,
  Duration maxDelay = FixUploadWorker.maxBackoff,
}) {
  final safeAttempt = attempt < 1 ? 1 : attempt;
  final shift = (safeAttempt - 1).clamp(0, 20);
  final expMs = math.min(
    maxDelay.inMilliseconds,
    baseDelay.inMilliseconds * (1 << shift),
  );
  final sample = randomDouble().clamp(0.0, 1.0);
  final jitteredMs = (expMs * sample).round();
  var minWaitMs = 0;
  if (retryAfter != null) {
    final maxRetryMs = FlightVisException.maxRetryAfter.inMilliseconds;
    minWaitMs = retryAfter.inMilliseconds.clamp(0, maxRetryMs);
  }
  final waitMs = math.max(jitteredMs, minWaitMs);
  return Duration(milliseconds: waitMs);
}

/// Store-and-forward uploader draining [FixUploadQueueStore] in chronological
/// batches of at most 100 fixes to `POST /api/ingest`.
///
/// Guarantees:
/// - **H-8 flight-ID isolation**: NEVER posts fixes whose `flightId` does not
///   match the currently open flight ([currentActiveFlightId]). Leftovers from
///   ended or other flights stay local-only in [queue], tagged with their
///   original `flightId` (never retagged, never uploaded onto a later flight).
/// - Batches of at most 100 fixes, ordered oldest-first (`tMs` asc, `seq` asc).
/// - A fix is removed from the queue ONLY after a 2xx response covering it
///   (or when a single unsplitable fix triggers 413/oversized and is logged &
///   dropped without blocking the queue).
/// - On 429: honours `Retry-After` (seconds or HTTP-date, clamped to `[0, 1h]`
///   per L-89) with exponential backoff + full jitter (base 2s, cap 5 min;
///   `Retry-After` is the minimum wait) and NEVER terminates active tracking.
/// - On 413 or server oversized error: splits the batch in half recursively
///   and records the smaller safe limit so an oversized batch is never resent
///   whole.
/// - **L-90 logging hygiene**: debug output is gated behind [enableDebugLogging]
///   (defaults to `kDebugMode`) so release logs emit zero flight ids or
///   timestamps.
/// - Pauses in background ([pause]) and resumes on foreground/connectivity
///   ([resume]).
class FixUploadWorker {
  FixUploadWorker({
    required this.queue,
    required this.uploadBatch,
    String? activeFlightId,
    String? Function()? activeFlightIdProvider,
    BackoffClock? clock,
    BackoffRandom? randomDouble,
    BackoffSleep? sleep,
    this.onStateChanged,
    this.logger,
    this.enableDebugLogging = kDebugMode,
  })  : _activeFlightId = activeFlightId,
        _activeFlightIdProvider = activeFlightIdProvider,
        _clock = clock ?? DateTime.now,
        _random = randomDouble ?? math.Random().nextDouble,
        _customSleep = sleep;

  static const int maxBatchSize = FixUploadQueueStore.maxBatchSize;
  static const Duration baseBackoff = Duration(seconds: 2);
  static const Duration maxBackoff = Duration(minutes: 5);
  static const Duration defaultStopDrainTimeout = Duration(seconds: 60);

  final FixUploadQueueStore queue;
  final BatchUploadCallback uploadBatch;
  final String? _activeFlightId;
  final String? Function()? _activeFlightIdProvider;
  final BackoffClock _clock;
  final BackoffRandom _random;
  final BackoffSleep? _customSleep;
  final VoidCallback? onStateChanged;
  final void Function(String message)? logger;
  final bool enableDebugLogging;

  bool _paused = false;
  bool _disposed = false;
  bool _draining = false;
  bool _stopDrainRequested = false;
  bool _retryRequested = false;
  bool _rateLimited = false;
  int _consecutiveFailures = 0;
  int _learnedMaxBatchSize = maxBatchSize;
  int _pendingCount = 0;
  int _droppedOversizedCount = 0;
  DateTime? _retryNotBefore;
  Completer<void>? _waitAbort;
  Timer? _waitTimer;
  Future<void>? _activeDrainFuture;

  /// Currently open flight id authorized for live `POST /api/ingest` uploads.
  /// Returns `null` when no flight is open (fail-closed: nothing is uploaded).
  String? get currentActiveFlightId {
    final raw = _activeFlightIdProvider != null
        ? _activeFlightIdProvider()
        : _activeFlightId;
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  bool get isPaused => _paused;
  bool get isDraining => _draining;
  bool get isRateLimited => _rateLimited;
  int get pendingCount => _pendingCount;
  int get learnedMaxBatchSize => _learnedMaxBatchSize;
  int get droppedOversizedCount => _droppedOversizedCount;

  void _log(String msg) {
    if (!enableDebugLogging) return;
    final cb = logger;
    if (cb != null) {
      cb(msg);
    } else if (kDebugMode) {
      debugPrint('FixUploadWorker: $msg');
    }
  }

  void _notify() {
    onStateChanged?.call();
  }

  /// Refreshes [pendingCount] from [queue] for [currentActiveFlightId] only
  /// (orphaned fixes from ended flights are excluded from the active count).
  Future<int> refreshPendingCount() async {
    final activeId = currentActiveFlightId;
    final c = activeId == null ? 0 : await queue.count(flightId: activeId);
    if (_pendingCount != c) {
      _pendingCount = c;
      _notify();
    }
    return c;
  }

  /// Enqueues [fix] (deduped by `(flightId, tMs)`) and triggers a flush if
  /// not paused and [fix] belongs to the currently open flight.
  Future<bool> enqueue(QueuedFixInput fix, {bool triggerFlush = true}) async {
    final added = await queue.enqueue(fix);
    await refreshPendingCount();
    final activeId = currentActiveFlightId;
    if (added &&
        triggerFlush &&
        !_paused &&
        !_disposed &&
        activeId != null &&
        fix.flightId.trim() == activeId) {
      unawaited(drain());
    }
    return added;
  }

  /// Enqueues all [fixes] (deduped by `(flightId, tMs)`) and triggers a flush
  /// if not paused and any fixes match the currently open flight.
  Future<int> enqueueAll(
    Iterable<QueuedFixInput> fixes, {
    bool triggerFlush = true,
  }) async {
    final added = await queue.enqueueAll(fixes);
    final pending = await refreshPendingCount();
    if (added > 0 && pending > 0 && triggerFlush && !_paused && !_disposed) {
      unawaited(drain());
    }
    return added;
  }

  /// Pauses background uploads and cancels any pending backoff wait.
  void pause() {
    _paused = true;
    _cancelWait();
    _notify();
  }

  /// Resumes uploads (e.g. on app foreground or connectivity restored) and
  /// immediately kicks off draining any pending backlog for the open flight.
  ///
  /// Clears stale transient network/5xx backoff on foreground resume while
  /// strictly preserving server-requested HTTP 429 `Retry-After` deadlines.
  Future<void> resume() async {
    if (_disposed) return;
    _paused = false;
    if (!_rateLimited) {
      _consecutiveFailures = 0;
      _retryNotBefore = null;
    }
    await refreshPendingCount();
    _notify();
    await drain();
  }

  /// Signals that network connectivity has returned (e.g. Traccar logged
  /// `Network restored` or a live 2xx upload succeeded).
  ///
  /// When not in a server-requested HTTP 429 `Retry-After` window, resets
  /// transient network/5xx backoff and immediately wakes any sleeping drain
  /// loop (or starts draining if idle). HTTP 429 `Retry-After` windows are
  /// strictly preserved.
  Future<void> onConnectivityRestored() async {
    if (_disposed || _paused) return;
    if (!_rateLimited) {
      _consecutiveFailures = 0;
      _retryNotBefore = null;
      if (_draining) {
        if (_waitAbort != null) {
          _cancelWait();
        } else {
          _retryRequested = true;
        }
        return;
      }
    }
    await refreshPendingCount();
    if (_pendingCount > 0) {
      await drain();
    }
  }

  void dispose() {
    _disposed = true;
    _paused = true;
    _cancelWait();
  }

  void _cancelWait() {
    _waitTimer?.cancel();
    _waitTimer = null;
    final wait = _waitAbort;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
    }
    _waitAbort = null;
  }

  Future<bool> _waitWithBackoff(
    Duration delay, {
    bool allowDuringStop = false,
  }) async {
    if (_paused || _disposed || (!allowDuringStop && _stopDrainRequested)) {
      return false;
    }
    if (delay <= Duration.zero) return true;
    final abort = Completer<void>();
    _waitAbort = abort;
    try {
      final customSleep = _customSleep;
      if (customSleep != null) {
        await Future.any<void>([
          customSleep(delay),
          abort.future,
        ]);
      } else {
        final done = Completer<void>();
        final timer = Timer(delay, () {
          if (!done.isCompleted) done.complete();
        });
        _waitTimer = timer;
        try {
          await Future.any<void>([
            done.future,
            abort.future,
          ]);
        } finally {
          timer.cancel();
          if (identical(_waitTimer, timer)) {
            _waitTimer = null;
          }
        }
      }
    } finally {
      if (identical(_waitAbort, abort)) {
        _waitAbort = null;
      }
    }
    return !_paused && !_disposed && (allowDuringStop || !_stopDrainRequested);
  }

  /// Drains queued fixes for [currentActiveFlightId] in chronological batches
  /// of `<=100` until empty for that flight, paused, disposed, blocked by a
  /// non-retryable auth/flight error, or bounded by [maxAttempts] / [maxDuration].
  ///
  /// Fixes tagged with any other `flightId` are NEVER uploaded (H-8).
  Future<void> drain({int? maxAttempts, Duration? maxDuration}) async {
    if (_draining || _paused || _disposed) return;
    final run = _drainLoop(
      maxAttempts: maxAttempts,
      maxDuration: maxDuration,
      forStop: false,
    );
    _activeDrainFuture = run;
    try {
      await run;
    } finally {
      if (identical(_activeDrainFuture, run)) {
        _activeDrainFuture = null;
      }
    }
  }

  /// H-8 pre-stop full drain: loops until the queue is empty for the currently
  /// open flight, honouring 429 `Retry-After` and exponential backoff, up to a
  /// total time cap of [timeout] (default 60s).
  ///
  /// Returns `true` when zero fixes remain for the active flight, or `false`
  /// if the time cap was reached or a non-retryable error halted drain (any
  /// remaining fixes stay persisted under their original `flightId` and are
  /// never uploaded onto a subsequent flight).
  Future<bool> drainForStop({
    Duration timeout = defaultStopDrainTimeout,
  }) async {
    if (_disposed) return false;
    final activeId = currentActiveFlightId;
    if (activeId == null) return true;

    final start = _clock();
    final deadline = start.add(timeout);

    // Coordinate cleanly if a background drain is already active (e.g. sleeping
    // in backoff) without silently skipping the Stop drain.
    final ongoing = _activeDrainFuture;
    if (_draining && ongoing != null) {
      _stopDrainRequested = true;
      _cancelWait();
      try {
        await ongoing;
      } catch (_) {}
      _stopDrainRequested = false;
    }

    if (_disposed) return false;
    _paused = false;

    final remaining = deadline.difference(_clock());
    if (remaining > Duration.zero) {
      final run = _drainLoop(
        maxDuration: remaining,
        deadline: deadline,
        forStop: true,
      );
      _activeDrainFuture = run;
      try {
        await run;
      } finally {
        if (identical(_activeDrainFuture, run)) {
          _activeDrainFuture = null;
        }
      }
    }

    final left = await refreshPendingCount();
    return left == 0;
  }

  Future<void> _drainLoop({
    int? maxAttempts,
    Duration? maxDuration,
    DateTime? deadline,
    required bool forStop,
  }) async {
    if (_draining || _paused || _disposed) return;
    _draining = true;
    var failedRounds = 0;
    var zeroDelayFailures = 0;
    final startedAt = _clock();
    final effectiveDeadline =
        deadline ?? (maxDuration != null ? startedAt.add(maxDuration) : null);
    var accumulatedSleep = Duration.zero;

    Duration? remainingBudget() {
      if (maxDuration == null) return null;
      final wallElapsed = _clock().difference(startedAt);
      final elapsed =
          wallElapsed > accumulatedSleep ? wallElapsed : accumulatedSleep;
      var rem = maxDuration - elapsed;
      if (effectiveDeadline != null) {
        final untilDeadline = effectiveDeadline.difference(_clock());
        if (untilDeadline < rem) rem = untilDeadline;
      }
      return rem;
    }

    try {
      while (!_paused && !_disposed && (forStop || !_stopDrainRequested)) {
        final activeId = currentActiveFlightId;
        if (activeId == null) {
          await refreshPendingCount();
          return;
        }

        final remBeforeBatch = remainingBudget();
        if (remBeforeBatch != null && remBeforeBatch <= Duration.zero) {
          _log('Drain time cap reached; ending drain');
          return;
        }

        // Respect any pending Retry-After / backoff deadline from an earlier
        // attempt (e.g. if a background drain was handed off to drainForStop).
        final notBefore = _retryNotBefore;
        if (notBefore != null) {
          final waitNeeded = notBefore.difference(_clock());
          if (waitNeeded > Duration.zero) {
            final rem = remainingBudget();
            if (rem != null && waitNeeded >= rem) {
              _log('Pending backoff exceeds remaining drain cap; halting');
              return;
            }
            final keepGoing = await _waitWithBackoff(
              waitNeeded,
              allowDuringStop: forStop,
            );
            accumulatedSleep += waitNeeded;
            if (!keepGoing) return;
          }
          _retryNotBefore = null;
        }

        final batch = await queue.peekOldestBatch(
          flightId: activeId,
          maxCount: _learnedMaxBatchSize,
        );
        if (batch.isEmpty) {
          if (_rateLimited) {
            _rateLimited = false;
            _notify();
          }
          await refreshPendingCount();
          return;
        }

        final result = await _sendSliceRecursive(
          batch,
          expectedFlightId: activeId,
        );
        await refreshPendingCount();

        if (result.outcome == _SliceOutcome.succeeded) {
          _consecutiveFailures = 0;
          zeroDelayFailures = 0;
          _retryNotBefore = null;
          if (_rateLimited) {
            _rateLimited = false;
            _notify();
          }
          continue;
        }
        if (result.outcome == _SliceOutcome.stopped) {
          return;
        }

        // Retryable failure (429 / 5xx / timeout / network).
        failedRounds++;
        final delay = result.retryDelay ?? Duration.zero;
        if (delay > Duration.zero) {
          _retryNotBefore = _clock().add(delay);
          zeroDelayFailures = 0;
        } else {
          zeroDelayFailures++;
        }

        final rem = remainingBudget();
        if (rem != null) {
          if (rem <= Duration.zero || delay >= rem) {
            _log('Backoff wait exceeds drain time cap; stopping drain');
            return;
          }
          // Safety guard if a test/clock uses 0ms jittered delays on persistent
          // non-429 failures so a bounded drain always terminates.
          if (zeroDelayFailures >= 8) {
            _log('Consecutive zero-delay failures hit bounded drain cap');
            return;
          }
        }

        if (maxAttempts != null && failedRounds >= maxAttempts) {
          await _waitWithBackoff(delay, allowDuringStop: forStop);
          accumulatedSleep += delay;
          if (!_paused && !_disposed) {
            _retryNotBefore = null;
          }
          return;
        }

        if (_retryRequested && !_rateLimited) {
          _retryRequested = false;
          _consecutiveFailures = 0;
          _retryNotBefore = null;
          continue;
        }

        final keepGoing = await _waitWithBackoff(
          delay,
          allowDuringStop: forStop,
        );
        accumulatedSleep += delay;
        if (!keepGoing) return;
        _retryNotBefore = null;
      }
    } finally {
      _draining = false;
      _retryRequested = false;
      await refreshPendingCount();
    }
  }

  Future<_SliceResult> _sendSliceRecursive(
    List<QueuedFix> slice, {
    required String expectedFlightId,
  }) async {
    if (_paused || _disposed) return const _SliceResult.stopped();
    if (slice.isEmpty) return const _SliceResult.succeeded();

    // H-8 defence in depth: verify the currently open flight still matches
    // EVERY fix in the slice right before issuing POST /api/ingest.
    final openId = currentActiveFlightId;
    if (openId == null || openId != expectedFlightId) {
      return const _SliceResult.stopped();
    }
    for (final fix in slice) {
      if (fix.flightId != openId) {
        _log('Refusing to upload fix belonging to non-active flight');
        return const _SliceResult.stopped();
      }
    }

    if (slice.length > _learnedMaxBatchSize) {
      for (var offset = 0;
          offset < slice.length;
          offset += _learnedMaxBatchSize) {
        final end = math.min(offset + _learnedMaxBatchSize, slice.length);
        final res = await _sendSliceRecursive(
          slice.sublist(offset, end),
          expectedFlightId: expectedFlightId,
        );
        if (res.outcome != _SliceOutcome.succeeded) return res;
      }
      return const _SliceResult.succeeded();
    }
    final flightMode = slice.first.flightMode;

    try {
      await uploadBatch(slice, flightMode: flightMode);
      // Remove ONLY the exact fixes covered by this 2xx response.
      await queue.removeKeys(slice.map((f) => f.dedupKey));
      _consecutiveFailures = 0;
      if (_rateLimited) {
        _rateLimited = false;
        _notify();
      }
      return const _SliceResult.succeeded();
    } on FlightVisException catch (e) {
      if (e.isOversizedBatch) {
        if (slice.length <= 1) {
          final dropped = slice.single;
          _droppedOversizedCount++;
          _log(
            'Dropping single oversized fix flight=${dropped.flightId} '
            't=${dropped.tMs} seq=${dropped.seq}: ${e.message}',
          );
          await queue.removeKeys([dropped.dedupKey]);
          return const _SliceResult.succeeded();
        }
        final mid = slice.length ~/ 2;
        final left = slice.sublist(0, mid);
        final right = slice.sublist(mid);
        // Never resend an oversized batch of size >= slice.length whole again.
        final nextCap = math.max(1, math.min(left.length, right.length));
        if (nextCap < _learnedMaxBatchSize) {
          _learnedMaxBatchSize = nextCap;
        }
        _log(
          'Batch of ${slice.length} oversized (${e.statusCode ?? e.message}); '
          'splitting into ${left.length} + ${right.length}',
        );
        final leftRes = await _sendSliceRecursive(
          left,
          expectedFlightId: expectedFlightId,
        );
        if (leftRes.outcome != _SliceOutcome.succeeded) return leftRes;
        return _sendSliceRecursive(
          right,
          expectedFlightId: expectedFlightId,
        );
      }

      if (e.statusCode == 429) {
        _consecutiveFailures++;
        if (!_rateLimited) {
          _rateLimited = true;
          _notify();
        }
        final retryAfter = e.resolveRetryAfter(now: _clock());
        final delay = computeUploadBackoff(
          attempt: _consecutiveFailures,
          randomDouble: _random,
          retryAfter: retryAfter,
        );
        _log(
          '429 rate limited (attempt $_consecutiveFailures, '
          'retryAfter=${retryAfter?.inSeconds}s); waiting ${delay.inMilliseconds}ms',
        );
        return _SliceResult.retryLater(delay);
      }

      if (e.statusCode == 401 || e.statusCode == 403) {
        _log(
          'Auth/club rejection (${e.statusCode}: ${e.message}); '
          'pausing upload queue without dropping fixes',
        );
        return const _SliceResult.stopped();
      }

      if (e.statusCode == 409) {
        _log(
          'Flight mismatch (${e.statusCode}: ${e.message}); '
          'halting queue drain without dropping fixes to avoid 409 hot-loop',
        );
        return const _SliceResult.stopped();
      }

      if (e.statusCode == 400) {
        final msg = e.message.trim().toLowerCase();
        if (msg.contains('no active flight')) {
          _log('Server reports no active flight; halting queue drain');
          return const _SliceResult.stopped();
        }
        if (slice.length == 1) {
          final dropped = slice.single;
          _log(
            'Dropping rejected single fix flight=${dropped.flightId} '
            't=${dropped.tMs}: ${e.message}',
          );
          await queue.removeKeys([dropped.dedupKey]);
          return const _SliceResult.succeeded();
        }
      }

      // Transient 5xx or other server error -> exponential backoff + full jitter.
      _consecutiveFailures++;
      final delay = computeUploadBackoff(
        attempt: _consecutiveFailures,
        randomDouble: _random,
      );
      _log(
        'Upload error HTTP ${e.statusCode} (attempt $_consecutiveFailures); '
        'waiting ${delay.inMilliseconds}ms',
      );
      return _SliceResult.retryLater(delay);
    } catch (e) {
      // Timeout / SocketException / transient client error -> keep fixes queued
      // (zero duplication on resend) and back off with full jitter.
      _consecutiveFailures++;
      final delay = computeUploadBackoff(
        attempt: _consecutiveFailures,
        randomDouble: _random,
      );
      _log(
        'Transient upload failure (attempt $_consecutiveFailures): $e; '
        'waiting ${delay.inMilliseconds}ms',
      );
      return _SliceResult.retryLater(delay);
    }
  }
}

enum _SliceOutcome { succeeded, retryLater, stopped }

class _SliceResult {
  const _SliceResult._(this.outcome, [this.retryDelay]);

  const _SliceResult.succeeded() : this._(_SliceOutcome.succeeded);
  const _SliceResult.stopped() : this._(_SliceOutcome.stopped);
  const _SliceResult.retryLater(Duration delay)
      : this._(_SliceOutcome.retryLater, delay);

  final _SliceOutcome outcome;
  final Duration? retryDelay;
}
