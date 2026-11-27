import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:traccar_client_sdk/traccar_client_sdk.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart';
import 'package:flight_vis/map/map_tile_config.dart';
import 'package:flight_vis/screens/login_screen.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/services/fix_upload_worker.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/native_fix_queue.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/fix_upload_queue.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import 'helpers/fake_tile_provider.dart';

class _TestSecureStore extends SecureStore {
  _TestSecureStore({
    this.sessionId,
    this.accountSessionId,
    this.deviceToken,
    this.personalDeviceToken,
  });

  String? sessionId;
  String? accountSessionId;
  String? deviceToken;
  String? personalDeviceToken;

  @override
  Future<String?> readDeviceToken() async => deviceToken;
  @override
  Future<void> writeDeviceToken(String token) async =>
      deviceToken = token.trim();
  @override
  Future<void> clearDeviceToken() async => deviceToken = null;

  @override
  Future<String?> readPersonalDeviceToken() async => personalDeviceToken;
  @override
  Future<void> writePersonalDeviceToken(String token) async =>
      personalDeviceToken = token.trim();
  @override
  Future<void> clearPersonalDeviceToken() async => personalDeviceToken = null;

  @override
  Future<String?> readSessionId() async => sessionId;
  @override
  Future<void> writeSessionId(String id) async => sessionId = id.trim();
  @override
  Future<void> clearSessionId() async => sessionId = null;

  @override
  Future<String?> readAccountSessionId() async => accountSessionId;
  @override
  Future<void> writeAccountSessionId(String id) async =>
      accountSessionId = id.trim();
  @override
  Future<void> clearAccountSessionId() async => accountSessionId = null;

  @override
  Future<void> clearAll() async {
    deviceToken = null;
    personalDeviceToken = null;
    sessionId = null;
    accountSessionId = null;
  }
}

class _TestPermissions extends FlightPermissionsClient {
  @override
  Future<FlightPermissionStatus> check() async => const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );

  @override
  Future<bool> requestFineLocation() async => true;
  @override
  Future<bool> requestBackgroundLocation() async => true;
  @override
  Future<bool> requestNotifications() async => true;
  @override
  Future<bool> requestBatteryExemption() async => true;
  @override
  Future<bool> openSettings() async => true;
  @override
  Future<void> openGapSettings(PermissionGap gap) async {}
}

class _TestTracker extends Fake implements TraccarClientSdk {
  bool started = false;
  int stopCalls = 0;
  final List<String> events = [];

  @override
  Future<void> init(Config config) async {}
  @override
  Future<void> setConfig(Config config) async {}

  @override
  Future<void> start() async {
    started = true;
    events.add('tracker.start');
  }

  @override
  Future<void> stop() async {
    started = false;
    stopCalls++;
    events.add('tracker.stop');
  }

  @override
  Future<bool> isTracking() async => started;
  @override
  Future<List<LogEntry>> getLogs() async => const [];
}

class _ThrowingEnqueueStore extends InMemoryFixUploadQueueStore {
  @override
  Future<int> enqueueAll(Iterable<QueuedFixInput> fixes) async {
    throw StateError('disk full');
  }
}

QueuedFixInput _fix(
  int index, {
  required String flightId,
  int baseMs = 1_760_000_000_000,
  String flightMode = 'club',
}) =>
    QueuedFixInput(
      flightId: flightId,
      tMs: baseMs + index * 1000,
      lat: -33.45 + index * 0.0001,
      lon: -70.55 - index * 0.0001,
      alt: 850.0 + index,
      speed: 40.0,
      course: 180.0,
      flightMode: flightMode,
    );

String _jwtWithEmail(String email) {
  String b64(Map<String, dynamic> obj) =>
      base64Url.encode(utf8.encode(jsonEncode(obj))).replaceAll('=', '');
  return '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({'email': email})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CheckinExpiryFormat.ensureInitialized();

  const trackingChannel = MethodChannel('cl.heavenly.flightvis/tracking');

  setUp(() {
    TrackingMapTestHooks.tileProviderOverride = FakeTileProvider();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, (_) async => null);
  });

  tearDown(() {
    TrackingMapTestHooks.tileProviderOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trackingChannel, null);
  });

  // ---------------------------------------------------------------------------
  // H-8 (BLOCKING): Flight-ID scoping, local-only retention, and Stop drain
  // ---------------------------------------------------------------------------
  group('H-8: Flight-ID isolation, bounded retention, and full Stop drain', () {
    test('leftovers from flight A exist while flight B is open -> NOTHING from A is POSTed, only B', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueueAll([
        _fix(0, flightId: 'flt-A', baseMs: 1_700_000_000_000),
        _fix(1, flightId: 'flt-A', baseMs: 1_700_000_000_000),
        _fix(2, flightId: 'flt-A', baseMs: 1_700_000_000_000),
        _fix(0, flightId: 'flt-B', baseMs: 1_700_000_100_000),
        _fix(1, flightId: 'flt-B', baseMs: 1_700_000_100_000),
      ]);

      final postedFlightIds = <String>[];
      final postedTimestamps = <int>[];
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        deviceToken: 'tok_club_0123456789abcdef0123456789ab',
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, FlightVisApiPaths.ingest);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final fixes =
              (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
          for (final f in fixes) {
            postedFlightIds.add(f['flight_id'] as String);
            postedTimestamps.add(f['t'] as int);
          }
          return http.Response(
            jsonEncode({'ok': true, 'accepted': fixes.length}),
            200,
          );
        }),
      );

      final worker = FixUploadWorker(
        queue: queue,
        activeFlightId: 'flt-B',
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) => client.ingestBatch(
          [for (final f in batch) f.toIngestJson()],
          deviceToken: client.deviceTokenForFlightMode(flightMode),
        ),
      );

      await worker.refreshPendingCount();
      // Pending upload count reflects ONLY open flight B (not orphaned A).
      expect(worker.pendingCount, 2);

      await worker.drain();

      // MockClient saw ONLY flight B's fixes — zero fixes from flight A.
      expect(postedFlightIds, ['flt-B', 'flt-B']);
      expect(postedFlightIds.contains('flt-A'), isFalse);
      expect(postedTimestamps, [1_700_000_100_000, 1_700_000_101_000]);

      // Flight A's leftovers remain local-only tagged to flt-A (never retagged/dropped).
      expect(await queue.count(flightId: 'flt-B'), 0);
      expect(await queue.count(flightId: 'flt-A'), 3);
      final orphans = await queue.listOrphanedByFlight(activeFlightId: 'flt-B');
      expect(orphans.keys, ['flt-A']);
      expect(orphans['flt-A'], hasLength(3));
      expect(orphans['flt-A']!.every((f) => f.flightId == 'flt-A'), isTrue);
    });

    test('fail-closed: worker with no open flightId posts nothing', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueue(_fix(0, flightId: 'flt-A'));
      var uploadCalls = 0;
      final worker = FixUploadWorker(
        queue: queue,
        activeFlightIdProvider: () => null,
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          uploadCalls++;
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );
      await worker.drain();
      expect(uploadCalls, 0);
      expect(await queue.count(flightId: 'flt-A'), 1);
    });

    testWidgets('Stop drains ALL of flight A fixes (including 429 retry and visible sending state) BEFORE POST /api/flights/A/end', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: 'flt-A',
        PreferencesStore.activeFlightModeKey: 'personal',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
      );

      final queue = InMemoryFixUploadQueueStore();
      // Plant leftover from an older ended flight Z -> must never be posted.
      await queue.enqueue(_fix(0, flightId: 'flt-Z', flightMode: 'personal'));

      final events = <String>[];
      final postedA = <int>[];
      var ingestCalls = 0;
      final holdFirstIngest = Completer<void>();

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.ingest) {
            ingestCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final fixes =
                (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
            for (final f in fixes) {
              expect(f['flight_id'], 'flt-A');
            }
            if (ingestCalls == 1) {
              await holdFirstIngest.future;
              events.add('ingest:429');
              return http.Response(
                jsonEncode({'error': 'rate limited'}),
                429,
                headers: {'retry-after': '2'},
              );
            }
            postedA.addAll(fixes.map((f) => f['t'] as int));
            events.add('ingest:200:${fixes.length}');
            return http.Response(
              jsonEncode({'ok': true, 'accepted': fixes.length}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.flightEnd('flt-A')) {
            events.add('end:flt-A');
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      var clockNow = DateTime.utc(2026, 11, 27, 12, 0, 0);
      final slept = <Duration>[];
      final worker = FixUploadWorker(
        queue: queue,
        activeFlightIdProvider: () =>
            prefs.activeFlightId() == 'flt-A' ? 'flt-A' : null,
        clock: () => clockNow,
        randomDouble: () => 0.0,
        sleep: (d) async {
          slept.add(d);
          clockNow = clockNow.add(d);
        },
        uploadBatch: (batch, {required String flightMode}) => client.ingestBatch(
          [for (final f in batch) f.toIngestJson()],
          deviceToken: client.deviceTokenForFlightMode(flightMode),
        ),
      );
      // Pause worker before tapping Stop so all 230 fixes are drained by Stop.
      worker.pause();

      var stopped = false;
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            key: const ValueKey('track-flt-A'),
            repo: repo,
            flightId: 'flt-A',
            tail: 'CC-A',
            flightMode: 'personal',
            tracking: TrackingService(
              tracker: _TestTracker(),
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: queue,
            uploadWorker: worker,
            onStopped: () => stopped = true,
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Now enqueue 230 offline fixes captured during flight A (paused until Stop drains).
      worker.pause();
      for (var i = 0; i < 230; i++) {
        await queue.enqueue(_fix(i, flightId: 'flt-A', flightMode: 'personal'));
      }
      await worker.refreshPendingCount();

      // Tap Stop and confirm.
      await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.trackingStopConfirm));
      await tester.pump();
      await tester.pump();

      // Visible "Enviando posiciones pendientes…" state shown while draining!
      expect(find.byKey(FlightVisTestKeys.trackingSendingPending), findsOneWidget);
      expect(find.text('Enviando posiciones pendientes…'), findsOneWidget);

      // Release held ingest -> drains all 230 fixes (100 + 100 + 30) after 429 retry, then ends.
      holdFirstIngest.complete();
      await tester.pumpAndSettle();

      expect(stopped, isTrue);
      expect(postedA, hasLength(230));
      expect(slept, [const Duration(seconds: 2)]);
      // Order strictly asserted: every ingest happens BEFORE POST /api/flights/flt-A/end.
      expect(events, [
        'ingest:429',
        'ingest:200:100',
        'ingest:200:100',
        'ingest:200:30',
        'end:flt-A',
      ]);
      expect(await queue.count(flightId: 'flt-A'), 0);
      // Older flight Z stayed local-only untouched.
      expect(await queue.count(flightId: 'flt-Z'), 1);
      expect(prefs.activeFlightId(), isNull);
    });

    testWidgets('Stop with persistent failure ends after cap, leaves A fixes tagged to A, then flight B starts and A fixes are still not posted', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: 'flt-A',
        PreferencesStore.activeFlightModeKey: 'personal',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
      );

      final sharedQueue = InMemoryFixUploadQueueStore();

      var failIngest = true;
      var endACalls = 0;
      final postedInFlightB = <String>[];

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.ingest) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final fixes =
                (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
            if (failIngest) {
              return http.Response(
                jsonEncode({'error': 'rate limited'}),
                429,
                headers: {'retry-after': '25'},
              );
            }
            for (final f in fixes) {
              postedInFlightB.add(f['flight_id'] as String);
            }
            return http.Response(
              jsonEncode({'ok': true, 'accepted': fixes.length}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.flightEnd('flt-A')) {
            endACalls++;
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      var clockNow = DateTime.utc(2026, 11, 27, 12, 0, 0);
      final sleptA = <Duration>[];
      final workerA = FixUploadWorker(
        queue: sharedQueue,
        activeFlightIdProvider: () =>
            prefs.activeFlightId() == 'flt-A' ? 'flt-A' : null,
        clock: () => clockNow,
        randomDouble: () => 0.0,
        sleep: (d) async {
          sleptA.add(d);
          clockNow = clockNow.add(d);
        },
        uploadBatch: (batch, {required String flightMode}) => client.ingestBatch(
          [for (final f in batch) f.toIngestJson()],
          deviceToken: client.deviceTokenForFlightMode(flightMode),
        ),
      );
      workerA.pause();

      var stoppedA = false;
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            key: const ValueKey('track-flt-A'),
            repo: repo,
            flightId: 'flt-A',
            tail: 'CC-A',
            flightMode: 'personal',
            tracking: TrackingService(
              tracker: _TestTracker(),
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: sharedQueue,
            uploadWorker: workerA,
            stopDrainTimeout: const Duration(seconds: 60),
            onStopped: () => stoppedA = true,
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Queue 2 fixes accumulated while offline/rate-limited during flight A.
      workerA.pause();
      await sharedQueue.enqueueAll([
        _fix(0, flightId: 'flt-A', flightMode: 'personal'),
        _fix(1, flightId: 'flt-A', flightMode: 'personal'),
      ]);
      await workerA.refreshPendingCount();

      await tester.tap(find.byKey(FlightVisTestKeys.trackingStop));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.trackingStopConfirm));
      await tester.pumpAndSettle();

      // Hit the 60s cap (25s + 25s = 50s slept; next 25s exceeds remaining 10s),
      // then ended flight A anyway and kept A's fixes tagged to flt-A!
      expect(stoppedA, isTrue);
      expect(endACalls, 1);
      expect(
        sleptA.fold<int>(0, (sum, d) => sum + d.inSeconds),
        lessThanOrEqualTo(60),
      );
      expect(await sharedQueue.count(flightId: 'flt-A'), 2);
      expect(prefs.activeFlightId(), isNull);

      // Now flight B starts online with the SAME shared queue + its own fix.
      failIngest = false;
      await prefs.setActiveFlightId('flt-B');
      await prefs.setActiveFlightMode('personal');
      await sharedQueue.enqueue(
        _fix(0, flightId: 'flt-B', baseMs: 1_760_005_000_000, flightMode: 'personal'),
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            key: const ValueKey('track-flt-B'),
            repo: repo,
            flightId: 'flt-B',
            tail: 'CC-B',
            flightMode: 'personal',
            tracking: TrackingService(
              tracker: _TestTracker(),
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: sharedQueue,
            onStopped: () {},
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ONLY flight B was uploaded; flight A's leftovers remain local-only tagged to A!
      expect(postedInFlightB, ['flt-B']);
      expect(postedInFlightB.contains('flt-A'), isFalse);
      expect(await sharedQueue.count(flightId: 'flt-B'), 0);
      expect(await sharedQueue.count(flightId: 'flt-A'), 2);
    });

    test('bounded orphaned retention keeps active flight and prunes orphans >7 days or >20 flights', () async {
      var now = DateTime.utc(2026, 11, 1, 12, 0, 0);
      final tempDir = await Directory.systemTemp.createTemp('fv_orphan_ret_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final store = FileFixUploadQueueStore(
        directoryProvider: () async => tempDir,
        accountBucket: 'acct_ret',
        clock: () => now,
      );

      // Enqueue active flight + 1 old orphaned flight on day 0.
      await store.enqueue(_fix(0, flightId: 'flt-active'));
      await store.enqueue(_fix(0, flightId: 'flt-old-day0'));

      // Advance 8 days -> enqueue 22 recent orphaned flights (1 minute apart).
      now = now.add(const Duration(days: 8));
      for (var i = 1; i <= 22; i++) {
        now = now.add(const Duration(minutes: 1));
        await store.enqueue(_fix(0, flightId: 'flt-recent-$i'));
      }

      final pruned = await store.pruneOrphaned(
        activeFlightId: 'flt-active',
        now: now,
      );
      // Dropped: flt-old-day0 (>7 days) + flt-recent-1 + flt-recent-2 (beyond 20 newest).
      expect(pruned, 3);
      // Active flight is NEVER pruned even though it is 8 days old.
      expect(await store.count(flightId: 'flt-active'), 1);

      // Reopen from disk to confirm retention was persisted.
      final reopened = FileFixUploadQueueStore(
        directoryProvider: () async => tempDir,
        accountBucket: 'acct_ret',
        clock: () => now,
      );
      final orphans = await reopened.listOrphanedByFlight(
        activeFlightId: 'flt-active',
      );
      expect(orphans.length, FixUploadQueueStore.maxOrphanedFlights);
      expect(orphans.containsKey('flt-old-day0'), isFalse);
      expect(orphans.containsKey('flt-recent-1'), isFalse);
      expect(orphans.containsKey('flt-recent-2'), isFalse);
      expect(orphans.containsKey('flt-recent-3'), isTrue);
      expect(orphans.containsKey('flt-recent-22'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // NATIVE QUEUE (Dart boundary via fake MethodChannel)
  // ---------------------------------------------------------------------------
  group('Native fix queue: tagging, import/merge/dedup, truncation, and H-8', () {
    test('TrackingService persists native active flight on start and clears on stop', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trackingChannel, (call) async {
        calls.add(call);
        return null;
      });

      final service = TrackingService(
        tracker: _TestTracker(),
        fixSource: InMemoryLocalFixSource(),
      );
      await service.initForFlight(
        baseUrl: 'https://flight.heavenly.cl',
        deviceToken: 'pers_tok_0123456789abcdef0123456789ab',
        flightId: 'flt-native-1',
        flightMode: 'personal',
      );
      expect(await service.start(), isTrue);

      final setCall =
          calls.firstWhere((c) => c.method == 'setActiveNativeFlight');
      expect(setCall.arguments, {
        'flightId': 'flt-native-1',
        'flightMode': 'personal',
      });

      await service.stop();
      expect(calls.any((c) => c.method == 'clearActiveNativeFlight'), isTrue);
    });

    test('importIntoStore merges native fixes, deduplicates by (flightId, tMs), truncates only after store persistence, and enforces H-8', () async {
      final nativeEntries = <Map<String, dynamic>>[
        // Flight A leftover recorded while Dart was dead
        {
          'flightId': 'flt-A',
          'flightMode': 'personal',
          'tMs': 1_760_000_001_000,
          'lat': -33.45,
          'lon': -70.55,
          'alt': 900.0,
        },
        // Duplicate of flt-A fix inside native payload
        {
          'flightId': 'flt-A',
          'flightMode': 'personal',
          'tMs': 1_760_000_001_000,
          'lat': -33.45,
          'lon': -70.55,
          'alt': 900.0,
        },
        // Flight B fix already present in Dart store (must dedup)
        {
          'flightId': 'flt-B',
          'flightMode': 'personal',
          'tMs': 1_760_000_010_000,
          'lat': -33.46,
          'lon': -70.56,
        },
        // Brand-new Flight B fix captured while Dart was dead
        {
          'flightId': 'flt-B',
          'flightMode': 'personal',
          'tMs': 1_760_000_011_000,
          'lat': -33.47,
          'lon': -70.57,
          'speed': 50.0,
          'course': 90.0,
        },
        // Invalid entry missing flightId -> skipped
        {
          'flightId': '',
          'tMs': 1_760_000_012_000,
          'lat': -33.48,
          'lon': -70.58,
        },
      ];

      final truncatedKeysCalls = <List<String>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trackingChannel, (call) async {
        if (call.method == 'readNativeFixQueue') {
          return nativeEntries;
        }
        if (call.method == 'truncateNativeFixQueue') {
          final args = call.arguments as Map<Object?, Object?>?;
          final keys = (args?['keys'] as List<Object?>?)
                  ?.whereType<String>()
                  .toList() ??
              <String>[];
          truncatedKeysCalls.add(keys);
          nativeEntries.removeWhere(
            (e) => keys.contains('${e['flightId']}|${e['tMs']}'),
          );
          return null;
        }
        return null;
      });

      final bridge = const NativeFixQueueBridge();

      // If store persistence fails, native queue MUST NOT be truncated.
      await expectLater(
        bridge.importIntoStore(_ThrowingEnqueueStore()),
        throwsStateError,
      );
      expect(truncatedKeysCalls, isEmpty);

      // Now import into real store pre-seeded with one flt-B fix for dedup test.
      final store = InMemoryFixUploadQueueStore();
      await store.enqueue(
        const QueuedFixInput(
          flightId: 'flt-B',
          flightMode: 'personal',
          tMs: 1_760_000_010_000,
          lat: -33.46,
          lon: -70.56,
        ),
      );

      final result = await bridge.importIntoStore(store);
      expect(result.readCount, 4); // 4 valid entries read
      expect(result.addedCount, 2); // 1 new flt-A + 1 new flt-B (2 deduped)
      expect(result.truncated, isTrue);
      expect(truncatedKeysCalls, hasLength(1));
      expect(
        truncatedKeysCalls.single.toSet(),
        {
          'flt-A|1760000001000',
          'flt-B|1760000010000',
          'flt-B|1760000011000',
        },
      );
      // Only the invalid blank-flightId entry wasn't in imported keys.
      expect(
        nativeEntries.where((e) => (e['flightId'] as String).isNotEmpty),
        isEmpty,
      );

      // H-8 check: draining while flt-B is open uploads ONLY flt-B, never flt-A!
      final postedFlightIds = <String>[];
      final postedTMs = <int>[];
      final worker = FixUploadWorker(
        queue: store,
        activeFlightId: 'flt-B',
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          expect(flightMode, 'personal');
          for (final f in batch) {
            postedFlightIds.add(f.flightId);
            postedTMs.add(f.tMs);
          }
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      expect(postedFlightIds, ['flt-B', 'flt-B']);
      expect(postedTMs, [1_760_000_010_000, 1_760_000_011_000]);
      expect(postedFlightIds.contains('flt-A'), isFalse);
      // Imported flight A fix stays preserved local-only tagged to flt-A.
      expect(await store.count(flightId: 'flt-A'), 1);
      expect(await store.count(flightId: 'flt-B'), 0);
    });

    testWidgets('TrackingScreen imports native queue on start/resume, truncates it, and never POSTs flight A fixes while flight B is open', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.activeFlightIdKey: 'flt-B',
        PreferencesStore.activeFlightModeKey: 'personal',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
      );

      final nativeEntries = <Map<String, dynamic>>[
        {
          'flightId': 'flt-A',
          'flightMode': 'personal',
          'tMs': 1_760_000_001_000,
          'lat': -33.45,
          'lon': -70.55,
        },
        {
          'flightId': 'flt-B',
          'flightMode': 'personal',
          'tMs': 1_760_000_050_000,
          'lat': -33.46,
          'lon': -70.56,
        },
      ];
      var truncateCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trackingChannel, (call) async {
        if (call.method == 'readNativeFixQueue') {
          return List<Map<String, dynamic>>.from(nativeEntries);
        }
        if (call.method == 'truncateNativeFixQueue') {
          truncateCalls++;
          final args = call.arguments as Map<Object?, Object?>?;
          final keys = (args?['keys'] as List<Object?>?)
                  ?.whereType<String>()
                  .toSet() ??
              <String>{};
          nativeEntries.removeWhere(
            (e) => keys.contains('${e['flightId']}|${e['tMs']}'),
          );
          return null;
        }
        return null;
      });

      final postedFlightIds = <String>[];
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        accountSessionId: 'acct-sess',
        personalDeviceToken: 'pers_tok_0123456789abcdef0123456789ab',
        httpClient: http_testing.MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path == FlightVisApiPaths.ingest) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final fixes =
                (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
            for (final f in fixes) {
              postedFlightIds.add(f['flight_id'] as String);
            }
            return http.Response(
              jsonEncode({'ok': true, 'accepted': fixes.length}),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);
      final queue = InMemoryFixUploadQueueStore();

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TrackingScreen(
            key: const ValueKey('native-track-B'),
            repo: repo,
            flightId: 'flt-B',
            tail: 'CC-B',
            flightMode: 'personal',
            tracking: TrackingService(
              tracker: _TestTracker(),
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: queue,
            onStopped: () {},
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(truncateCalls, greaterThanOrEqualTo(1));
      expect(nativeEntries, isEmpty);
      expect(postedFlightIds, ['flt-B']);
      expect(postedFlightIds.contains('flt-A'), isFalse);
      expect(await queue.count(flightId: 'flt-B'), 0);
      expect(await queue.count(flightId: 'flt-A'), 1);
    });
  });

  // ---------------------------------------------------------------------------
  // M-30: Magic-link auto-complete marker & confirmation dialog
  // ---------------------------------------------------------------------------
  group('M-30: Account magic-link marker & confirmation dialog', () {
    test('pure auto-complete gate and deep-link email extraction from query or JWT claims', () {
      const now = 1_760_000_000_000;
      const fresh = PendingMagicLinkRequest(
        nonce: 'n1',
        email: 'pilot@example.cl',
        expiresAtMs: now + 60_000,
      );
      const expired = PendingMagicLinkRequest(
        nonce: 'n2',
        email: 'pilot@example.cl',
        expiresAtMs: now - 1,
      );

      expect(
        shouldAutoCompleteAccountMagicLink(
          pendingRequest: fresh,
          nowMs: now,
          isSignedIn: false,
          isTracking: false,
        ),
        isTrue,
      );
      expect(
        shouldAutoCompleteAccountMagicLink(
          pendingRequest: null,
          nowMs: now,
          isSignedIn: false,
          isTracking: false,
        ),
        isFalse,
      );
      expect(
        shouldAutoCompleteAccountMagicLink(
          pendingRequest: expired,
          nowMs: now,
          isSignedIn: false,
          isTracking: false,
        ),
        isFalse,
      );
      expect(
        shouldAutoCompleteAccountMagicLink(
          pendingRequest: fresh,
          nowMs: now,
          isSignedIn: true,
          isTracking: false,
        ),
        isFalse,
      );
      expect(
        shouldAutoCompleteAccountMagicLink(
          pendingRequest: fresh,
          nowMs: now,
          isSignedIn: false,
          isTracking: true,
        ),
        isFalse,
      );

      final fromQuery = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=opaque_1&email=ana@example.cl',
        ),
      ) as AccountMagicLinkDeepLink;
      expect(fromQuery.email, 'ana@example.cl');

      final jwt = _jwtWithEmail('jwtpilot@example.cl');
      final fromJwt = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=$jwt',
        ),
      ) as AccountMagicLinkDeepLink;
      expect(fromJwt.email, 'jwtpilot@example.cl');

      final opaque = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=opaque_no_email',
        ),
      ) as AccountMagicLinkDeepLink;
      expect(opaque.email, isNull);
    });

    testWidgets('LoginScreen records fresh 30-min marker on magic-link request and signup', (tester) async {
      final fixedNow = DateTime.utc(2026, 11, 27, 15, 0, 0);
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountMagicLink) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.url.path == FlightVisApiPaths.accountSignup) {
            return http.Response(jsonEncode({'ok': true}), 201);
          }
          return http.Response('{}', 404);
        }),
      );
      final repo = AppRepository(
        secure: _TestSecureStore(),
        prefs: prefs,
        client: client,
        clock: () => fixedNow,
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LoginScreen(
            repo: repo,
            onLoggedIn: () {},
            signupAvailabilityProbe: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Correo'),
        'magic@example.cl',
      );
      await tester.tap(find.text('Enviar enlace mágico'));
      await tester.pumpAndSettle();

      final magicMarker = prefs.pendingMagicLinkRequest();
      expect(magicMarker, isNotNull);
      expect(magicMarker!.email, 'magic@example.cl');
      expect(magicMarker.nonce, isNotEmpty);
      expect(
        magicMarker.expiresAtMs,
        fixedNow.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      );

      await prefs.clearPendingMagicLinkRequest();
      await tester.tap(find.byKey(FlightVisTestKeys.loginRegister));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(FlightVisTestKeys.loginSignupEmail),
        'signup@example.cl',
      );
      await tester.tap(find.byKey(FlightVisTestKeys.loginSignupSubmit));
      await tester.pumpAndSettle();

      final signupMarker = prefs.pendingMagicLinkRequest();
      expect(signupMarker, isNotNull);
      expect(signupMarker!.email, 'signup@example.cl');
      expect(signupMarker.isFresh(fixedNow.millisecondsSinceEpoch), isTrue);
    });

    testWidgets('fresh marker auto-completes with NO dialog and clears marker', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final clockNow = DateTime.utc(2026, 11, 27, 16, 0, 0);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      await prefs.recordMagicLinkRequest(
        email: 'fresh@example.cl',
        nowMs: clockNow.millisecondsSinceEpoch,
      );
      final secure = _TestSecureStore();
      var completeCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountAuthMagicComplete) {
            completeCalls++;
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-fresh',
                  'email': 'fresh@example.cl',
                  'emailVerified': true,
                },
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
              headers: {'set-cookie': 'fv_account_session=sess-fresh; Path=/'},
            );
          }
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {'id': 'acct-fresh', 'email': 'fresh@example.cl'},
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'test-install-id',
        deviceModelProvider: () async => 'Pixel Test',
        clock: () => clockNow,
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          clock: () => clockNow,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      await DeepLinkTestHooks.dispatch(
        const AccountMagicLinkDeepLink(token: 'tok_fresh'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(FlightVisTestKeys.magicLinkConfirmDialog), findsNothing);
      expect(completeCalls, 1);
      expect(await secure.readAccountSessionId(), 'sess-fresh');
      expect(prefs.pendingMagicLinkRequest(), isNull);
    });

    testWidgets('no marker and expired marker show confirm dialog; Cancel skips complete, Confirm completes', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      var clockNow = DateTime.utc(2026, 11, 27, 16, 0, 0);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore();
      var completeCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountAuthMagicComplete) {
            completeCalls++;
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-confirmed',
                  'email': 'confirmed@example.cl',
                  'emailVerified': true,
                },
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
              headers: {
                'set-cookie': 'fv_account_session=sess-confirmed; Path=/',
              },
            );
          }
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {
                  'id': 'acct-confirmed',
                  'email': 'confirmed@example.cl',
                },
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'test-install-id',
        deviceModelProvider: () async => 'Pixel Test',
        clock: () => clockNow,
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          clock: () => clockNow,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      // 1. No marker + opaque token (no email) -> generic confirm dialog, Cancel makes NO complete call.
      final f1 = DeepLinkTestHooks.dispatch(
        const AccountMagicLinkDeepLink(token: 'tok_unsolicited'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.magicLinkConfirmDialog), findsOneWidget);
      expect(find.text('¿Iniciar sesión con este enlace?'), findsOneWidget);
      expect(completeCalls, 0);

      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmCancel));
      await tester.pumpAndSettle();
      await f1;
      expect(completeCalls, 0);
      expect(await secure.readAccountSessionId(), isNull);

      // 2. Expired marker (31 min old) + link with email claim -> email confirm dialog, Confirm completes!
      await prefs.recordMagicLinkRequest(
        email: 'old@example.cl',
        nowMs: clockNow.millisecondsSinceEpoch,
      );
      clockNow = clockNow.add(const Duration(minutes: 31));

      final jwtLink = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=${_jwtWithEmail('confirmed@example.cl')}',
        ),
      )!;
      final f2 = DeepLinkTestHooks.dispatch(jwtLink);
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.magicLinkConfirmDialog), findsOneWidget);
      expect(
        find.text('¿Iniciar sesión como confirmed@example.cl?'),
        findsOneWidget,
      );
      expect(completeCalls, 0);

      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmProceed));
      await tester.pumpAndSettle();
      await f2;
      expect(completeCalls, 1);
      expect(await secure.readAccountSessionId(), 'sess-confirmed');
    });

    testWidgets('already signed in requires confirmation even with fresh marker; Cancel keeps current user, Confirm switches', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final clockNow = DateTime.utc(2026, 11, 27, 16, 0, 0);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      await prefs.recordMagicLinkRequest(
        email: 'userB@example.cl',
        nowMs: clockNow.millisecondsSinceEpoch,
      );
      final secure = _TestSecureStore(
        accountSessionId: 'sess-userA',
        personalDeviceToken: 'pers_tok_userA_0123456789abcdef0123456',
      );
      var currentAcct = 'acct-A';
      var completeCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {
                  'id': currentAcct,
                  'email': currentAcct == 'acct-A'
                      ? 'userA@example.cl'
                      : 'userB@example.cl',
                },
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.accountAuthMagicComplete) {
            completeCalls++;
            currentAcct = 'acct-B';
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-B',
                  'email': 'userB@example.cl',
                  'emailVerified': true,
                },
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
              headers: {'set-cookie': 'fv_account_session=sess-userB; Path=/'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'test-install-id',
        deviceModelProvider: () async => 'Pixel Test',
        clock: () => clockNow,
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          clock: () => clockNow,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      const link = AccountMagicLinkDeepLink(
        token: 'tok_swap',
        email: 'userB@example.cl',
      );
      // Cancel -> stays signed in as userA, no complete call.
      final fCancel = DeepLinkTestHooks.dispatch(link);
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.magicLinkConfirmDialog), findsOneWidget);
      expect(find.text('¿Iniciar sesión como userB@example.cl?'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmCancel));
      await tester.pumpAndSettle();
      await fCancel;
      expect(completeCalls, 0);
      expect(await secure.readAccountSessionId(), 'sess-userA');

      // Confirm -> completes and switches to userB (and M-31 clears userA's personal token!).
      final fConfirm = DeepLinkTestHooks.dispatch(link);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmProceed));
      await tester.pumpAndSettle();
      await fConfirm;
      expect(completeCalls, 1);
      expect(await secure.readAccountSessionId(), 'sess-userB');
      expect(await secure.readPersonalDeviceToken(), isNull);
      expect(client.personalDeviceToken, isNull);
    });

    testWidgets('while tracking, magic link confirms first; Cancel keeps tracking, Confirm stops tracking via M-24 BEFORE completing', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final clockNow = DateTime.utc(2026, 11, 27, 16, 0, 0);

      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
        PreferencesStore.activeFlightIdKey: 'flt-live-1',
        PreferencesStore.activeFlightModeKey: 'personal',
        PreferencesStore.activeFlightTailKey: 'CC-LIVE',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        accountSessionId: 'sess-acctA',
        personalDeviceToken: 'pers_tok_acctA_0123456789abcdef0123456',
      );
      final tracker = _TestTracker();
      var currentAcct = 'acct-A';
      var completeCalls = 0;

      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {
                  'id': currentAcct,
                  'email': currentAcct == 'acct-A'
                      ? 'a@example.cl'
                      : 'b@example.cl',
                },
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.meFlights) {
            return http.Response(
              jsonEncode({
                'flights': [
                  {'id': 'flt-live-1', 'tail': 'CC-LIVE', 'status': 'active'},
                ],
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.accountAuthMagicComplete) {
            tracker.events.add('magic.complete');
            completeCalls++;
            currentAcct = 'acct-B';
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-B',
                  'email': 'b@example.cl',
                  'emailVerified': true,
                },
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
              headers: {'set-cookie': 'fv_account_session=sess-acctB; Path=/'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'test-install-id',
        deviceModelProvider: () async => 'Pixel Test',
        clock: () => clockNow,
      );

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          clock: () => clockNow,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: tracker,
            fixSource: InMemoryLocalFixSource(),
          ),
          uploadQueue: InMemoryFixUploadQueueStore(),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TrackingScreen), findsOneWidget);
      expect(tracker.started, isTrue);
      final stopsBefore = tracker.stopCalls;

      // Cancel -> tracking continues untouched, zero complete calls.
      final fCancel = DeepLinkTestHooks.dispatch(
        const AccountMagicLinkDeepLink(token: 'tok_midflight'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(FlightVisTestKeys.magicLinkConfirmDialog), findsOneWidget);
      expect(
        find.text(
          'Tienes un vuelo en curso. Si continúas, se detendrá el seguimiento actual.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmCancel));
      await tester.pumpAndSettle();
      await fCancel;

      expect(completeCalls, 0);
      expect(tracker.stopCalls, stopsBefore);
      expect(tracker.started, isTrue);
      expect(prefs.activeFlightId(), 'flt-live-1');
      expect(find.byType(TrackingScreen), findsOneWidget);

      // Confirm -> stops tracking via M-24 path FIRST, THEN calls magic/complete!
      tracker.events.clear();
      final fConfirm = DeepLinkTestHooks.dispatch(
        const AccountMagicLinkDeepLink(token: 'tok_midflight'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.magicLinkConfirmProceed));
      await tester.pumpAndSettle();
      await fConfirm;

      expect(completeCalls, 1);
      expect(tracker.started, isFalse);
      expect(prefs.activeFlightId(), isNull);
      expect(find.byType(TrackingScreen), findsNothing);
      expect(find.byKey(FlightVisTestKeys.hub), findsOneWidget);
      // Assert M-24 stop happened strictly BEFORE magic/complete.
      final stopIdx = tracker.events.indexOf('tracker.stop');
      final completeIdx = tracker.events.indexOf('magic.complete');
      expect(stopIdx, greaterThanOrEqualTo(0));
      expect(completeIdx, greaterThan(stopIdx));
    });
  });

  // ---------------------------------------------------------------------------
  // M-31: Clear fv_personal_device_token on logout, expiry (M-24), account change
  // ---------------------------------------------------------------------------
  group('M-31: Clear fv_personal_device_token on logout, session expiry, and account change', () {
    testWidgets('logout clears fv_personal_device_token from SecureStore and client', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        accountSessionId: 'acct-sess-out',
        personalDeviceToken: 'pers_tok_to_clear_0123456789abcdef012',
      );
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {'id': 'acct-out', 'email': 'out@example.cl'},
                'email_verified': true,
                'activeMembershipId': null,
                'memberships': [],
              }),
              200,
            );
          }
          if (request.url.path == FlightVisApiPaths.accountLogout) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);

      await tester.pumpWidget(
        FlightVisApp(
          repo: repo,
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        await secure.readPersonalDeviceToken(),
        'pers_tok_to_clear_0123456789abcdef012',
      );
      expect(client.personalDeviceToken, isNotNull);

      await tester.tap(find.byIcon(Icons.logout));
      await tester.pumpAndSettle();

      expect(await secure.readPersonalDeviceToken(), isNull);
      expect(client.personalDeviceToken, isNull);
    });

    testWidgets('session expiry (M-24 401 and 200 pilot:null) clears fv_personal_device_token', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);

      // 1) Account session 401 expiry (without invalid_device reason!)
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs1 = await PreferencesStore.open();
      final secure1 = _TestSecureStore(
        accountSessionId: 'expired-acct-sess',
        personalDeviceToken: 'pers_tok_401_0123456789abcdef01234567',
      );
      final client1 = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(jsonEncode({'error': 'unauthorized'}), 401);
          }
          return http.Response('{}', 200);
        }),
      );
      await tester.pumpWidget(
        FlightVisApp(
          key: const ValueKey('expiry-401-app'),
          repo: AppRepository(secure: secure1, prefs: prefs1, client: client1),
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(await secure1.readPersonalDeviceToken(), isNull);
      expect(client1.personalDeviceToken, isNull);
      expect(find.byKey(FlightVisTestKeys.hubSessionExpiredBanner), findsOneWidget);

      // 2) Legacy club session 200 pilot:null expiry also clears any lingering personal token
      SharedPreferences.setMockInitialValues({
        PreferencesStore.permissionsOnboardingKey: true,
      });
      final prefs2 = await PreferencesStore.open();
      final secure2 = _TestSecureStore(
        sessionId: 'stale-club-sess',
        deviceToken: 'club_tok_keep_0123456789abcdef01234567',
        personalDeviceToken: 'pers_tok_nullpilot_0123456789abcdef01',
      );
      final client2 = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.clubMe) {
            return http.Response(jsonEncode({'pilot': null}), 200);
          }
          return http.Response('{}', 200);
        }),
      );
      await tester.pumpWidget(
        FlightVisApp(
          key: const ValueKey('expiry-pilot-null-app'),
          repo: AppRepository(secure: secure2, prefs: prefs2, client: client2),
          bindPlatformDeepLinks: false,
          stopStickyTrackerOnRestore: false,
          trackingService: TrackingService(
            tracker: _TestTracker(),
            fixSource: InMemoryLocalFixSource(),
          ),
          permissions: _TestPermissions(),
          localFlightStore: InMemoryLocalFlightStore(),
          tileProvider: FakeTileProvider(),
          enableMapPolling: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(await secure2.readPersonalDeviceToken(), isNull);
      expect(client2.personalDeviceToken, isNull);
      // Club device token remains intact per F3/M-24 contract.
      expect(
        await secure2.readDeviceToken(),
        'club_tok_keep_0123456789abcdef01234567',
      );
    });

    testWidgets('account change on LoginScreen password login clears previous account fv_personal_device_token', (tester) async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.lastSignedInAccountIdKey: 'acct-prev',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        personalDeviceToken: 'pers_tok_prev_acct_0123456789abcdef01',
      );
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        personalDeviceToken: 'pers_tok_prev_acct_0123456789abcdef01',
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.accountLogin) {
            // Account B has a club membership and does NOT return a personal device.
            return http.Response(
              jsonEncode({
                'ok': true,
                'account': {
                  'id': 'acct-new',
                  'email': 'new@example.cl',
                  'emailVerified': true,
                },
                'activeMembershipId': 'mem-1',
                'memberships': [
                  {
                    'id': 'mem-1',
                    'clubId': 'c1',
                    'slug': 'cas',
                    'name': 'CAS',
                    'role': 'pilot',
                    'status': 'active',
                  },
                ],
                'device': {
                  'id': 'dev-club-1',
                  'token': 'club_tok_new_0123456789abcdef012345678',
                  'label': 'Android',
                },
              }),
              200,
              headers: {'set-cookie': 'fv_account_session=sess-new; Path=/'},
            );
          }
          if (request.url.path == FlightVisApiPaths.accountMe) {
            return http.Response(
              jsonEncode({
                'account': {'id': 'acct-new', 'email': 'new@example.cl'},
                'email_verified': true,
                'activeMembershipId': 'mem-1',
                'memberships': [
                  {
                    'id': 'mem-1',
                    'clubId': 'c1',
                    'slug': 'cas',
                    'name': 'CAS',
                    'role': 'pilot',
                    'status': 'active',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final repo = AppRepository(
        secure: secure,
        prefs: prefs,
        client: client,
        installIdProvider: () async => 'install-switch',
        deviceModelProvider: () async => 'Pixel',
      );

      var loggedIn = false;
      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: LoginScreen(
            repo: repo,
            onLoggedIn: () => loggedIn = true,
            signupAvailabilityProbe: (_) async => false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Correo'),
        'new@example.cl',
      );
      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Contraseña'),
        'secret1234',
      );
      await tester.tap(find.text('Iniciar sesión'));
      await tester.pumpAndSettle();

      expect(loggedIn, isTrue);
      // Old account's personal device token MUST be cleared!
      expect(await secure.readPersonalDeviceToken(), isNull);
      expect(client.personalDeviceToken, isNull);
      expect(prefs.lastSignedInAccountId(), 'acct-new');
    });

    test('clearPersonalDeviceTokenIfAccountChanged keeps token for same account and clears on different account id', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesStore.lastSignedInAccountIdKey: 'acct-same',
      });
      final prefs = await PreferencesStore.open();
      final secure = _TestSecureStore(
        personalDeviceToken: 'pers_tok_same_0123456789abcdef0123456',
      );
      final client = FlightVisClient(
        baseUrl: 'https://flight.heavenly.cl',
        personalDeviceToken: 'pers_tok_same_0123456789abcdef0123456',
      );
      final repo = AppRepository(secure: secure, prefs: prefs, client: client);

      expect(
        await repo.clearPersonalDeviceTokenIfAccountChanged('acct-same'),
        isFalse,
      );
      expect(
        await secure.readPersonalDeviceToken(),
        'pers_tok_same_0123456789abcdef0123456',
      );

      expect(
        await repo.clearPersonalDeviceTokenIfAccountChanged('acct-other'),
        isTrue,
      );
      expect(await secure.readPersonalDeviceToken(), isNull);
      expect(client.personalDeviceToken, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // L-89: Clamp Retry-After (numeric seconds & HTTP-date) to [0, 1 hour]
  // ---------------------------------------------------------------------------
  group('L-89: Retry-After clamped to [0, 1 hour]', () {
    test('clamps numeric seconds, past/future HTTP-dates, and huge values to [0, 1h]', () {
      final now = DateTime.utc(2026, 11, 27, 12, 0, 0);

      // Numeric seconds
      expect(FlightVisException.parseRetryAfterDuration('-15', now: now), Duration.zero);
      expect(FlightVisException.parseRetryAfterDuration('0', now: now), Duration.zero);
      expect(
        FlightVisException.parseRetryAfterDuration('45', now: now),
        const Duration(seconds: 45),
      );
      expect(
        FlightVisException.parseRetryAfterDuration('3600', now: now),
        const Duration(hours: 1),
      );
      expect(
        FlightVisException.parseRetryAfterDuration('86400', now: now),
        const Duration(hours: 1),
      );
      expect(
        FlightVisException.parseRetryAfterDuration(
          '99999999999999999999999999',
          now: now,
        ),
        const Duration(hours: 1),
      );
      expect(
        FlightVisException.parseRetryAfterSeconds('999999', now: now),
        3600,
      );

      // HTTP-date: past -> 0, normal -> delta, huge (>1h) -> 1h
      final pastDate = HttpDate.format(now.subtract(const Duration(minutes: 5)));
      expect(
        FlightVisException.parseRetryAfterDuration(pastDate, now: now),
        Duration.zero,
      );
      final nearDate = HttpDate.format(now.add(const Duration(seconds: 90)));
      expect(
        FlightVisException.parseRetryAfterDuration(nearDate, now: now),
        const Duration(seconds: 90),
      );
      final farDate = HttpDate.format(now.add(const Duration(hours: 6)));
      expect(
        FlightVisException.parseRetryAfterDuration(farDate, now: now),
        const Duration(hours: 1),
      );
      final hugeDate = HttpDate.format(now.add(const Duration(days: 365)));
      expect(
        FlightVisException.parseRetryAfterDuration(hugeDate, now: now),
        const Duration(hours: 1),
      );
      expect(
        FlightVisException.parseRetryAfterSeconds(hugeDate, now: now),
        3600,
      );

      // resolveRetryAfter also clamps direct retryAfterSeconds
      final ex = FlightVisException(
        'rate limited',
        statusCode: 429,
        retryAfterSeconds: 99999,
      );
      expect(ex.resolveRetryAfter(now: now), const Duration(hours: 1));
    });

    test('FixUploadWorker caps 429 sleep at 1 hour for huge numeric and HTTP-date Retry-After', () async {
      final now = DateTime.utc(2026, 11, 27, 12, 0, 0);
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueue(_fix(0, flightId: 'flt-r'));
      final slept = <Duration>[];
      var attempt = 0;

      final worker = FixUploadWorker(
        queue: queue,
        activeFlightId: 'flt-r',
        clock: () => now,
        randomDouble: () => 0.0,
        sleep: (d) async => slept.add(d),
        uploadBatch: (batch, {required String flightMode}) async {
          attempt++;
          if (attempt == 1) {
            throw FlightVisException(
              'rate limited',
              statusCode: 429,
              retryAfterRaw: '999999',
            );
          }
          if (attempt == 2) {
            throw FlightVisException(
              'rate limited',
              statusCode: 429,
              retryAfterRaw: HttpDate.format(now.add(const Duration(hours: 12))),
            );
          }
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      expect(slept, [const Duration(hours: 1), const Duration(hours: 1)]);
      expect(await queue.count(), 0);
    });
  });

  // ---------------------------------------------------------------------------
  // L-90: Gate debug logging behind kDebugMode / injectable flag
  // ---------------------------------------------------------------------------
  group('L-90: Debug logging gated when disabled (no flight ids / timestamps in release)', () {
    test('FixUploadWorker does not invoke logger when enableDebugLogging is false', () async {
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueueAll([
        _fix(0, flightId: 'secret-flt-99'),
        _fix(1, flightId: 'secret-flt-99'),
      ]);

      final releaseLogs = <String>[];
      var call = 0;
      final worker = FixUploadWorker(
        queue: queue,
        activeFlightId: 'secret-flt-99',
        enableDebugLogging: false,
        logger: releaseLogs.add,
        randomDouble: () => 0.0,
        sleep: (_) async {},
        uploadBatch: (batch, {required String flightMode}) async {
          call++;
          if (call == 1) {
            throw FlightVisException('oversized', statusCode: 413);
          }
          if (call == 2) {
            throw FlightVisException('oversized', statusCode: 413);
          }
          if (call == 3) {
            throw FlightVisException('rate limited', statusCode: 429, retryAfterRaw: '1');
          }
          if (call == 4) {
            throw TimeoutException('offline');
          }
          return IngestBatchResult(ok: true, accepted: batch.length);
        },
      );

      await worker.drain();

      expect(worker.droppedOversizedCount, 1);
      expect(releaseLogs, isEmpty);
    });

    test('NativeFixQueueBridge does not invoke logger when enableDebugLogging is false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(trackingChannel, (call) async {
        if (call.method == 'setActiveNativeFlight') {
          throw PlatformException(code: 'io_error', message: 'disk error');
        }
        if (call.method == 'readNativeFixQueue') {
          return [
            {
              'flightId': 'secret-flt-77',
              'flightMode': 'club',
              'tMs': 1_760_000_000_000,
              'lat': -33.45,
              'lon': -70.55,
            },
          ];
        }
        return null;
      });

      final releaseLogs = <String>[];
      final releaseBridge = NativeFixQueueBridge(
        enableDebugLogging: false,
        logger: releaseLogs.add,
      );
      await releaseBridge.setActiveFlight(flightId: 'secret-flt-77');
      await releaseBridge.importIntoStore(InMemoryFixUploadQueueStore());
      expect(releaseLogs, isEmpty);

      final debugLogs = <String>[];
      final debugBridge = NativeFixQueueBridge(
        enableDebugLogging: true,
        logger: debugLogs.add,
      );
      await debugBridge.setActiveFlight(flightId: 'secret-flt-77');
      await debugBridge.importIntoStore(InMemoryFixUploadQueueStore());
      expect(debugLogs, isNotEmpty);
      // Even debug logs never contain raw flightId or timestamps.
      expect(debugLogs.any((l) => l.contains('secret-flt-77')), isFalse);
      expect(debugLogs.any((l) => l.contains('1760000000000')), isFalse);
    });
  });
}
