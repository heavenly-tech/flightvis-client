import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/services/fix_upload_worker.dart';
import 'package:flight_vis/storage/fix_upload_queue.dart';

QueuedFixInput _makeFix(
  int index, {
  String flightId = 'flt-1',
  int baseMs = 1_700_000_000_000,
  String flightMode = 'club',
}) =>
    QueuedFixInput(
      flightId: flightId,
      tMs: baseMs + index * 1000,
      lat: -33.45 + index * 0.0001,
      lon: -70.55 - index * 0.0001,
      alt: 900.0 + index,
      speed: 42.5,
      course: 180.0,
      accuracy: 4.0,
      flightMode: flightMode,
    );

void main() {
  group('Store-and-forward batching, ordering & wire payload', () {
    test('250 queued fixes upload as 3 batches of <=100 (100, 100, 50) oldest-first via POST /api/ingest', () async {
      final queue = InMemoryFixUploadQueueStore();
      // Enqueue out of order to prove oldest-first chronological ordering.
      for (var i = 249; i >= 0; i--) {
        await queue.enqueue(_makeFix(i, flightId: 'flt-250', flightMode: 'personal'));
      }
      expect(await queue.count(), 250);

      final receivedBatchSizes = <int>[];
      final receivedTimestamps = <int>[];
      final receivedSeqs = <int>[];
      String? authHeader;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
        httpClient: http_testing.MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, FlightVisApiPaths.ingest);
          authHeader = request.headers['Authorization'];
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final fixes = (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
          receivedBatchSizes.add(fixes.length);
          for (final f in fixes) {
            receivedTimestamps.add(f['t'] as int);
            receivedSeqs.add(f['seq'] as int);
            expect(f['flight_id'], 'flt-250');
            expect(f['lat'], isA<num>());
            expect(f['lon'], isA<num>());
          }
          return http.Response(
            jsonEncode({'ok': true, 'accepted': fixes.length}),
            200,
          );
        }),
      );

      final worker = FixUploadWorker(
        queue: queue,
        uploadBatch: (batch, {required String flightMode}) => client.ingestBatch(
          [for (final f in batch) f.toIngestJson()],
          deviceToken: client.deviceTokenForFlightMode(flightMode),
        ),
        sleep: (_) async {},
      );

      await worker.drain();

      expect(receivedBatchSizes, [100, 100, 50]);
      expect(receivedTimestamps, hasLength(250));
      for (var i = 1; i < receivedTimestamps.length; i++) {
        expect(receivedTimestamps[i], greaterThan(receivedTimestamps[i - 1]));
      }
      expect(receivedSeqs.toSet(), hasLength(250));
      expect(authHeader, 'Bearer pers_tok_0123456789abcdef0123456789ab');
      expect(await queue.count(), 0);
    });
  });

  group('429 Retry-After, exponential backoff & full jitter', () {
    test('429 with Retry-After=7 waits >= 7s before retrying and preserves queued fixes until 2xx', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueueAll([_makeFix(0), _makeFix(1), _makeFix(2)]);

      final sleptDurations = <Duration>[];
      var attempts = 0;

      final worker = FixUploadWorker(
        queue: queue,
        clock: () => DateTime.utc(2026, 11, 27, 12, 0, 0),
        // Even with jitter random=0.0 (which gives 0ms backoff), Retry-After=7
        // MUST take precedence as the minimum wait!
        randomDouble: () => 0.0,
        sleep: (d) async => sleptDurations.add(d),
        uploadBatch: (batch, {required String flightMode}) async {
          attempts++;
          if (attempts == 1) {
            throw FlightVisException(
              'rate limited',
              statusCode: 429,
              retryAfterSeconds: 7,
              retryAfterRaw: '7',
            );
          }
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      expect(attempts, 2);
      expect(sleptDurations, hasLength(1));
      expect(sleptDurations.single, greaterThanOrEqualTo(const Duration(seconds: 7)));
      expect(await queue.count(), 0);
      expect(worker.isRateLimited, isFalse);
    });

    test('429 with HTTP-date Retry-After parses relative to injectable clock and waits >= delta', () async {
      final now = DateTime.utc(2026, 11, 27, 12, 0, 0);
      final targetDate = HttpDate.format(now.add(const Duration(seconds: 12)));
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueue(_makeFix(0));

      final slept = <Duration>[];
      var attempts = 0;
      final worker = FixUploadWorker(
        queue: queue,
        clock: () => now,
        randomDouble: () => 0.0,
        sleep: (d) async => slept.add(d),
        uploadBatch: (batch, {required String flightMode}) async {
          attempts++;
          if (attempts == 1) {
            throw FlightVisException(
              'rate limited',
              statusCode: 429,
              retryAfterRaw: targetDate,
            );
          }
          return const IngestBatchResult(ok: true, accepted: 1);
        },
      );

      await worker.drain();

      expect(attempts, 2);
      expect(slept.single, greaterThanOrEqualTo(const Duration(seconds: 12)));
      expect(await queue.count(), 0);
    });

    test('exponential backoff grows from base 2s, caps at 5 min (300s), and full jitter stays within [0, ceiling]', () {
      // With random = 1.0, full jitter equals the exact exponential ceiling:
      // 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 300s, 300s...
      final expectedCeilingSeconds = [2, 4, 8, 16, 32, 64, 128, 256, 300, 300];
      for (var attempt = 1; attempt <= expectedCeilingSeconds.length; attempt++) {
        final maxDelay = computeUploadBackoff(
          attempt: attempt,
          randomDouble: () => 1.0,
        );
        final minDelay = computeUploadBackoff(
          attempt: attempt,
          randomDouble: () => 0.0,
        );
        final midDelay = computeUploadBackoff(
          attempt: attempt,
          randomDouble: () => 0.5,
        );
        final capMs = expectedCeilingSeconds[attempt - 1] * 1000;
        expect(maxDelay.inMilliseconds, capMs);
        expect(minDelay.inMilliseconds, 0);
        expect(midDelay.inMilliseconds, capMs ~/ 2);
        expect(midDelay.inMilliseconds, greaterThanOrEqualTo(0));
        expect(midDelay.inMilliseconds, lessThanOrEqualTo(capMs));
      }

      // Retry-After overrides smaller jittered backoff as minimum wait.
      final withRetryAfter = computeUploadBackoff(
        attempt: 1,
        randomDouble: () => 0.25, // 500ms jittered
        retryAfter: const Duration(seconds: 7),
      );
      expect(withRetryAfter, const Duration(seconds: 7));

      // When jittered exponential backoff exceeds Retry-After, larger backoff wins.
      final largerBackoff = computeUploadBackoff(
        attempt: 4, // 16s ceiling
        randomDouble: () => 1.0, // 16s
        retryAfter: const Duration(seconds: 7),
      );
      expect(largerBackoff, const Duration(seconds: 16));
    });
  });

  group('413 / oversized recursive batch splitting', () {
    test('413 splits batch in half recursively, never resends oversized batch whole, and succeeds', () async {
      final queue = InMemoryFixUploadQueueStore();
      for (var i = 0; i < 40; i++) {
        await queue.enqueue(_makeFix(i));
      }

      final attemptedSizes = <int>[];
      final uploadedTimes = <int>[];

      final worker = FixUploadWorker(
        queue: queue,
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          attemptedSizes.add(batch.length);
          // Reject any batch > 10 fixes with HTTP 413 Payload Too Large.
          if (batch.length > 10) {
            throw FlightVisException(
              'payload too large',
              statusCode: 413,
            );
          }
          uploadedTimes.addAll(batch.map((f) => f.tMs));
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      // 40 -> 413 -> split 20 + 20 -> 20 -> 413 -> split 10 + 10 -> OK!
      // Neither 40 nor 20 is ever resent whole after failing with 413.
      expect(attemptedSizes.where((s) => s == 40), hasLength(1));
      expect(attemptedSizes.where((s) => s == 20), hasLength(1));
      expect(attemptedSizes.every((s) => s <= 40), isTrue);
      // Every single one of the 40 fixes eventually arrived in exact order.
      expect(uploadedTimes, hasLength(40));
      for (var i = 1; i < uploadedTimes.length; i++) {
        expect(uploadedTimes[i], greaterThan(uploadedTimes[i - 1]));
      }
      expect(await queue.count(), 0);
      expect(worker.learnedMaxBatchSize, lessThanOrEqualTo(10));
    });

    test('single fix that still fails oversized/413 is logged and dropped without blocking remaining fixes', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueueAll([_makeFix(0), _makeFix(1), _makeFix(2)]);

      final logs = <String>[];
      final acceptedTimes = <int>[];
      final badTimestamp = _makeFix(1).tMs;

      final worker = FixUploadWorker(
        queue: queue,
        sleep: (_) async {},
        logger: logs.add,
        uploadBatch: (batch, {required String flightMode}) async {
          if (batch.any((f) => f.tMs == badTimestamp)) {
            throw FlightVisException(
              'oversized fix payload',
              statusCode: 413,
            );
          }
          acceptedTimes.addAll(batch.map((f) => f.tMs));
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      expect(worker.droppedOversizedCount, 1);
      expect(acceptedTimes, [_makeFix(0).tMs, _makeFix(2).tMs]);
      expect(await queue.count(), 0);
      expect(logs.any((l) => l.contains('Dropping single oversized fix')), isTrue);
    });
  });

  group('Dedup on timeout/resend, lifecycle pause/resume, and disk persistence', () {
    test('resend after timeout does not duplicate queue entries and removes only after 2xx', () async {
      final queue = InMemoryFixUploadQueueStore();
      final f0 = _makeFix(0, flightId: 'flt-dedup');
      final f1 = _makeFix(1, flightId: 'flt-dedup');
      expect(await queue.enqueue(f0), isTrue);
      expect(await queue.enqueue(f1), isTrue);
      // Re-enqueuing identical (flightId, tMs) must be deduplicated.
      expect(await queue.enqueue(f0), isFalse);
      expect(await queue.count(), 2);

      var attempts = 0;
      final worker = FixUploadWorker(
        queue: queue,
        randomDouble: () => 0.0,
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          attempts++;
          if (attempts == 1) {
            throw TimeoutException('socket read timed out');
          }
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      // First attempt times out -> entries stay in queue with NO duplicates.
      await worker.drain(maxAttempts: 1);
      expect(attempts, 1);
      expect(await queue.count(), 2);

      // Even if live capture re-enqueues the same fixes after timeout, still 2 entries!
      expect(await queue.enqueueAll([f0, f1]), 0);
      expect(await queue.count(), 2);

      // Second drain succeeds -> exact 2 entries removed.
      await worker.drain();
      expect(attempts, 2);
      expect(await queue.count(), 0);
    });

    test('FileFixUploadQueueStore persists across reopen under account bucket and survives restart', () async {
      final tempDir = await Directory.systemTemp.createTemp('fv_upload_queue_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final store1 = FileFixUploadQueueStore(
        directoryProvider: () async => tempDir,
        accountBucket: 'acct_deadbeef',
      );
      await store1.enqueueAll([
        _makeFix(2, flightId: 'flt-persist', flightMode: 'personal'),
        _makeFix(0, flightId: 'flt-persist', flightMode: 'personal'),
        _makeFix(1, flightId: 'flt-persist', flightMode: 'personal'),
      ]);
      // Duplicate enqueue ignored on disk as well.
      expect(
        await store1.enqueue(
          _makeFix(1, flightId: 'flt-persist', flightMode: 'personal'),
        ),
        isFalse,
      );

      // Reopen a brand-new FileFixUploadQueueStore on the same directory.
      final store2 = FileFixUploadQueueStore(
        directoryProvider: () async => tempDir,
        accountBucket: 'acct_deadbeef',
      );
      final loaded = await store2.listAll();
      expect(loaded, hasLength(3));
      expect(loaded.map((f) => f.tMs).toList(), [
        _makeFix(0).tMs,
        _makeFix(1).tMs,
        _makeFix(2).tMs,
      ]);
      expect(loaded.every((f) => f.flightMode == 'personal'), isTrue);

      // Next enqueued fix after reopen keeps monotonic seq strictly > previous max seq.
      final maxSeqBefore = loaded.map((f) => f.seq).reduce((a, b) => a > b ? a : b);
      await store2.enqueue(
        _makeFix(3, flightId: 'flt-persist', flightMode: 'personal'),
      );
      final afterAdd = await store2.listAll();
      expect(afterAdd.last.seq, greaterThan(maxSeqBefore));

      // Remove first two keys and verify persistence after another reopen.
      await store2.removeKeys([loaded[0].dedupKey, loaded[1].dedupKey]);
      final store3 = FileFixUploadQueueStore(
        directoryProvider: () async => tempDir,
        accountBucket: 'acct_deadbeef',
      );
      final remaining = await store3.listAll();
      expect(remaining.map((f) => f.tMs).toList(), [
        _makeFix(2).tMs,
        _makeFix(3).tMs,
      ]);
    });

    test('pause stops uploading while backgrounded and resume drains backlog', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueueAll([_makeFix(0), _makeFix(1)]);

      var uploadCalls = 0;
      final worker = FixUploadWorker(
        queue: queue,
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          uploadCalls++;
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      worker.pause();
      await worker.drain();
      expect(uploadCalls, 0);
      expect(await queue.count(), 2);

      await worker.resume();
      expect(uploadCalls, 1);
      expect(await queue.count(), 0);
    });
  });
}
