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

/// Exponential backoff with full jitter and `Retry-After` minimum-wait floor.
///
/// - Base: 2 seconds
/// - Cap: 5 minutes (300 seconds)
/// - Full jitter: uniform in `[0, min(cap, base * 2^(attempt - 1))]`
/// - `Retry-After` (integer seconds or HTTP-date) takes precedence as the
///   minimum wait (`max(jitteredBackoff, retryAfter)`).
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
  final minWaitMs =
      retryAfter == null ? 0 : math.max(0, retryAfter.inMilliseconds);
  final waitMs = math.max(jitteredMs, minWaitMs);
  return Duration(milliseconds: waitMs);
}

/// Store-and-forward uploader draining [FixUploadQueueStore] in chronological
/// batches of at most 100 fixes to `POST /api/ingest`.
///
/// Guarantees:
/// - Batches of at most 100 fixes, ordered oldest-first (`tMs` asc, `seq` asc).
/// - A fix is removed from the queue ONLY after a 2xx response covering it
///   (or when a single unsplitable fix triggers 413/oversized and is logged &
///   dropped without blocking the queue).
/// - On 429: honours `Retry-After` (seconds or HTTP-date) with exponential
///   backoff + full jitter (base 2s, cap 5 min; `Retry-After` is the minimum
///   wait) and NEVER terminates active tracking.
/// - On 413 or server oversized error: splits the batch in half recursively
///   and records the smaller safe limit so an oversized batch is never resent
///   whole.
/// - Pauses in background ([pause]) and resumes on foreground/connectivity
///   ([resume]).
class FixUploadWorker {
  FixUploadWorker({
    required this.queue,
    required this.uploadBatch,
    BackoffClock? clock,
    BackoffRandom? randomDouble,
    BackoffSleep? sleep,
    this.onStateChanged,
    this.logger,
  })  : _clock = clock ?? DateTime.now,
        _random = randomDouble ?? math.Random().nextDouble,
        _sleep = sleep ?? _defaultSleep;

  static const int maxBatchSize = FixUploadQueueStore.maxBatchSize;
  static const Duration baseBackoff = Duration(seconds: 2);
  static const Duration maxBackoff = Duration(minutes: 5);

  final FixUploadQueueStore queue;
  final BatchUploadCallback uploadBatch;
  final BackoffClock _clock;
  final BackoffRandom _random;
  final BackoffSleep _sleep;
  final VoidCallback? onStateChanged;
  final void Function(String message)? logger;

  bool _paused = false;
  bool _disposed = false;
  bool _draining = false;
  bool _rateLimited = false;
  int _consecutiveFailures = 0;
  int _learnedMaxBatchSize = maxBatchSize;
  int _pendingCount = 0;
  int _droppedOversizedCount = 0;
  Completer<void>? _waitAbort;

  bool get isPaused => _paused;
  bool get isRateLimited => _rateLimited;
  int get pendingCount => _pendingCount;
  int get learnedMaxBatchSize => _learnedMaxBatchSize;
  int get droppedOversizedCount => _droppedOversizedCount;

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  void _log(String msg) {
    final cb = logger;
    if (cb != null) {
      cb(msg);
    } else {
      debugPrint('FixUploadWorker: $msg');
    }
  }

  void _notify() {
    onStateChanged?.call();
  }

  /// Refreshes [pendingCount] from [queue].
  Future<int> refreshPendingCount() async {
    final c = await queue.count();
    if (_pendingCount != c) {
      _pendingCount = c;
      _notify();
    }
    return c;
  }

  /// Enqueues [fix] (deduped by `(flightId, tMs)`) and triggers a flush if
  /// not paused.
  Future<bool> enqueue(QueuedFixInput fix, {bool triggerFlush = true}) async {
    final added = await queue.enqueue(fix);
    await refreshPendingCount();
    if (added && triggerFlush && !_paused && !_disposed) {
      unawaited(drain());
    }
    return added;
  }

  /// Enqueues all [fixes] (deduped by `(flightId, tMs)`) and triggers a flush
  /// if not paused.
  Future<int> enqueueAll(
    Iterable<QueuedFixInput> fixes, {
    bool triggerFlush = true,
  }) async {
    final added = await queue.enqueueAll(fixes);
    await refreshPendingCount();
    if (added > 0 && triggerFlush && !_paused && !_disposed) {
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
  /// immediately kicks off draining any pending backlog.
  Future<void> resume() async {
    if (_disposed) return;
    _paused = false;
    await refreshPendingCount();
    _notify();
    await drain();
  }

  void dispose() {
    _disposed = true;
    _paused = true;
    _cancelWait();
  }

  void _cancelWait() {
    final wait = _waitAbort;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
    }
    _waitAbort = null;
  }

  Future<bool> _waitWithBackoff(Duration delay) async {
    if (_paused || _disposed) return false;
    if (delay <= Duration.zero) return true;
    final abort = Completer<void>();
    _waitAbort = abort;
    try {
      await Future.any<void>([
        _sleep(delay),
        abort.future,
      ]);
    } finally {
      if (identical(_waitAbort, abort)) {
        _waitAbort = null;
      }
    }
    return !_paused && !_disposed;
  }

  /// Drains queued fixes in chronological batches of `<=100` until the queue is
  /// empty, paused, disposed, or blocked by a non-retryable auth/flight error.
  ///
  /// When [maxAttempts] is supplied (useful for bounded tests or best-effort
  /// pre-stop flushes), stops after that many failed retry rounds.
  Future<void> drain({int? maxAttempts}) async {
    if (_draining || _paused || _disposed) return;
    _draining = true;
    var failedRounds = 0;
    try {
      while (!_paused && !_disposed) {
        final batch =
            await queue.peekOldestBatch(maxCount: _learnedMaxBatchSize);
        if (batch.isEmpty) {
          if (_rateLimited) {
            _rateLimited = false;
            _notify();
          }
          await refreshPendingCount();
          return;
        }
        final outcome = await _sendSliceRecursive(batch);
        await refreshPendingCount();
        if (outcome == _SliceOutcome.succeeded) {
          _consecutiveFailures = 0;
          if (_rateLimited) {
            _rateLimited = false;
            _notify();
          }
          continue;
        }
        if (outcome == _SliceOutcome.stopped) {
          return;
        }
        // Retryable failure (429 / 5xx / timeout / network).
        failedRounds++;
        if (maxAttempts != null && failedRounds >= maxAttempts) {
          return;
        }
      }
    } finally {
      _draining = false;
      await refreshPendingCount();
    }
  }

  Future<_SliceOutcome> _sendSliceRecursive(List<QueuedFix> slice) async {
    if (_paused || _disposed) return _SliceOutcome.stopped;
    if (slice.isEmpty) return _SliceOutcome.succeeded;
    if (slice.length > _learnedMaxBatchSize) {
      for (var offset = 0; offset < slice.length; offset += _learnedMaxBatchSize) {
        final end = math.min(offset + _learnedMaxBatchSize, slice.length);
        final outcome = await _sendSliceRecursive(slice.sublist(offset, end));
        if (outcome != _SliceOutcome.succeeded) return outcome;
      }
      return _SliceOutcome.succeeded;
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
      return _SliceOutcome.succeeded;
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
          return _SliceOutcome.succeeded;
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
        final leftOutcome = await _sendSliceRecursive(left);
        if (leftOutcome != _SliceOutcome.succeeded) return leftOutcome;
        return _sendSliceRecursive(right);
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
        final keepGoing = await _waitWithBackoff(delay);
        return keepGoing ? _SliceOutcome.retryLater : _SliceOutcome.stopped;
      }

      if (e.statusCode == 401 || e.statusCode == 403) {
        _log(
          'Auth/club rejection (${e.statusCode}: ${e.message}); '
          'pausing upload queue without dropping fixes',
        );
        return _SliceOutcome.stopped;
      }

      if (e.statusCode == 400) {
        final msg = e.message.trim().toLowerCase();
        if (msg.contains('no active flight')) {
          _log('Server reports no active flight; halting queue drain');
          return _SliceOutcome.stopped;
        }
        if (slice.length == 1) {
          final dropped = slice.single;
          _log(
            'Dropping rejected single fix flight=${dropped.flightId} '
            't=${dropped.tMs}: ${e.message}',
          );
          await queue.removeKeys([dropped.dedupKey]);
          return _SliceOutcome.succeeded;
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
      final keepGoing = await _waitWithBackoff(delay);
      return keepGoing ? _SliceOutcome.retryLater : _SliceOutcome.stopped;
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
      final keepGoing = await _waitWithBackoff(delay);
      return keepGoing ? _SliceOutcome.retryLater : _SliceOutcome.stopped;
    }
  }
}

enum _SliceOutcome { succeeded, retryLater, stopped }
