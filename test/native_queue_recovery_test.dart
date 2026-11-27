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
import 'package:flight_vis/map/own_trail_buffer.dart';
import 'package:flight_vis/screens/tracking_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/fix_upload_worker.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/local_fix_source.dart';
import 'package:flight_vis/services/tracking_lifecycle.dart';
import 'package:flight_vis/services/tracking_service.dart';
import 'package:flight_vis/storage/fix_upload_queue.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/util/checkin_expiry_format.dart';

import 'helpers/fake_tile_provider.dart';

class _TestSecureStore extends SecureStore {
  _TestSecureStore({
    this.accountSessionId,
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

class _ControllableTracker extends Fake implements TraccarClientSdk {
  bool started = false;
  int stopCalls = 0;
  final List<LogEntry> logs = [];
  int _nextLogTimeMs = 1_760_000_000_000;

  void addLog(String message) {
    _nextLogTimeMs += 1000;
    logs.add(LogEntry(time: _nextLogTimeMs, message: message));
  }

  @override
  Future<void> init(Config config) async {}

  @override
  Future<void> setConfig(Config config) async {}

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
    stopCalls++;
  }

  @override
  Future<bool> isTracking() async => started;

  @override
  Future<List<LogEntry>> getLogs() async => List<LogEntry>.unmodifiable(logs);
}

Map<String, dynamic> _nativeFixMap(
  int index, {
  required String flightId,
  int baseMs = 1_760_100_000_000,
  String flightMode = 'personal',
}) =>
    {
      'flightId': flightId,
      'flightMode': flightMode,
      'tMs': baseMs + index * 1000,
      'lat': -33.45 + index * 0.0001,
      'lon': -70.55 - index * 0.0001,
      'alt': 900.0 + index,
      'speed': 42.0,
      'course': 180.0,
    };

LocalFix _localFix(
  int index, {
  int baseMs = 1_760_200_000_000,
}) =>
    LocalFix(
      timeMs: baseMs + index * 1000,
      latitude: -33.45 + index * 0.0001,
      longitude: -70.55 - index * 0.0001,
      altitude: 850.0 + index,
      speed: 40.0,
      bearing: 90.0,
    );

QueuedFixInput _queuedFix(
  int index, {
  required String flightId,
  int baseMs = 1_760_000_000_000,
  String flightMode = 'personal',
}) =>
    QueuedFixInput(
      flightId: flightId,
      tMs: baseMs + index * 1000,
      lat: -33.45 + index * 0.0001,
      lon: -70.55 - index * 0.0001,
      alt: 850.0 + index,
      speed: 40.0,
      course: 90.0,
      flightMode: flightMode,
    );

/// Reads persisted queue counts directly from disk (`queue.json`) synchronously,
/// avoiding any `FakeAsync` <-> `runAsync` zone interleaving while proving real
/// atomic on-disk persistence.
int _readDiskQueueCount(
  Directory tempDir,
  String accountBucket, {
  String? flightId,
}) {
  final sep = Platform.pathSeparator;
  final file = File(
    '${tempDir.path}${sep}upload_queue$sep$accountBucket${sep}queue.json',
  );
  if (!file.existsSync()) return 0;
  final raw = file.readAsStringSync();
  if (raw.trim().isEmpty) return 0;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final items = (decoded['items'] as List<dynamic>? ?? const []);
  if (flightId == null) return items.length;
  var count = 0;
  for (final item in items) {
    if (item is Map<String, dynamic> && item['flightId'] == flightId) {
      count++;
    }
  }
  return count;
}

/// Bounded pump helper that never uses unbounded `pumpAndSettle` with periodic
/// timers. When [yieldRealIo] is true, yields briefly to the real event loop so
/// disk-backed [FileFixUploadQueueStore] operations complete deterministically.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxTicks = 80,
  Duration fakeStep = const Duration(milliseconds: 50),
  bool yieldRealIo = false,
}) async {
  for (var i = 0; i < maxTicks; i++) {
    if (condition()) return;
    if (yieldRealIo) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pump(fakeStep);
  }
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
  // Group 1: ISOLATE DEATH / cold restart
  // ---------------------------------------------------------------------------
  group('Isolate death / cold restart native queue recovery', () {
    testWidgets(
      'cold start via FlightVisApp._restore imports native queue, deduplicates, truncates, POSTs flt-B in <=100 batches in order, and never POSTs flt-A',
      (tester) async {
        tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
        addTearDown(tester.platformDispatcher.clearLocaleTestValue);

        final tempDir = Directory.systemTemp.createTempSync('fv_iso_death_1_');
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        // Empty Dart FixUploadQueueStore: Dart isolate died before persisting
        // anything into the Dart queue.
        final dartQueue = FileFixUploadQueueStore(
          directoryProvider: () async => tempDir,
          accountBucket: 'acct_iso_1',
        );
        expect(_readDiskQueueCount(tempDir, 'acct_iso_1'), 0);

        // Native queue holds 215 unique fixes for flt-B (scrambled + 5 exact
        // duplicates to verify dedup on import) PLUS 6 older fixes for flt-A.
        const fltBBaseMs = 1_760_100_000_000;
        const fltABaseMs = 1_760_050_000_000;
        final nativeEntries = <Map<String, dynamic>>[
          for (var i = 0; i < 6; i++)
            _nativeFixMap(i, flightId: 'flt-A', baseMs: fltABaseMs),
          // Reverse order to prove strict oldest-first chronological upload.
          for (var i = 214; i >= 0; i--)
            _nativeFixMap(i, flightId: 'flt-B', baseMs: fltBBaseMs),
          // Duplicate timestamps inside native payload -> must deduplicate.
          for (final dup in [0, 50, 99, 100, 214])
            _nativeFixMap(dup, flightId: 'flt-B', baseMs: fltBBaseMs),
        ];

        var readCalls = 0;
        final truncatedKeySets = <Set<String>>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(trackingChannel, (call) async {
          if (call.method == 'readNativeFixQueue') {
            readCalls++;
            return List<Map<String, dynamic>>.from(nativeEntries);
          }
          if (call.method == 'truncateNativeFixQueue') {
            final args = call.arguments as Map<Object?, Object?>?;
            final keys = (args?['keys'] as List<Object?>?)
                    ?.whereType<String>()
                    .toSet() ??
                <String>{};
            truncatedKeySets.add(keys);
            nativeEntries.removeWhere(
              (e) => keys.contains('${e['flightId']}|${e['tMs']}'),
            );
            return null;
          }
          return null;
        });

        SharedPreferences.setMockInitialValues({
          PreferencesStore.permissionsOnboardingKey: true,
          PreferencesStore.activeFlightIdKey: 'flt-B',
          PreferencesStore.activeFlightModeKey: 'personal',
          PreferencesStore.activeFlightTailKey: 'CC-ISOB',
        });
        final prefs = await PreferencesStore.open();
        final secure = _TestSecureStore(
          accountSessionId: 'acct-sess-iso1',
          personalDeviceToken: 'pers_tok_iso1_0123456789abcdef012345',
        );

        final batchSizes = <int>[];
        final postedFlightIds = <String>[];
        final postedTimestamps = <int>[];
        final authHeaders = <String?>[];

        final client = FlightVisClient(
          baseUrl: 'https://flight.heavenly.cl',
          httpClient: http_testing.MockClient((request) async {
            if (request.url.path == FlightVisApiPaths.accountMe) {
              return http.Response(
                jsonEncode({
                  'account': {'id': 'acct-iso-1', 'email': 'iso1@example.cl'},
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
                    {'id': 'flt-B', 'tail': 'CC-ISOB', 'status': 'active'},
                  ],
                }),
                200,
              );
            }
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.ingest) {
              authHeaders.add(request.headers['Authorization']);
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final fixes =
                  (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
              batchSizes.add(fixes.length);
              for (final f in fixes) {
                postedFlightIds.add(f['flight_id'] as String);
                postedTimestamps.add(f['t'] as int);
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
        final tracker = _ControllableTracker();

        await tester.pumpWidget(
          FlightVisApp(
            key: const ValueKey('cold-start-iso-1'),
            repo: repo,
            bindPlatformDeepLinks: false,
            stopStickyTrackerOnRestore: false,
            trackingService: TrackingService(
              tracker: tracker,
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: dartQueue,
            permissions: _TestPermissions(),
            localFlightStore: InMemoryLocalFlightStore(),
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              postedTimestamps.length >= 215 &&
              nativeEntries.isEmpty &&
              _readDiskQueueCount(tempDir, 'acct_iso_1', flightId: 'flt-B') ==
                  0,
          maxTicks: 100,
          yieldRealIo: true,
        );
        // Pump a few extra frames to ensure no duplicate extra requests fire.
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byType(TrackingScreen), findsOneWidget);
        expect(tracker.started, isTrue);

        // Native queue read, deduplicated, and truncated.
        expect(readCalls, greaterThanOrEqualTo(1));
        expect(truncatedKeySets, isNotEmpty);
        expect(nativeEntries, isEmpty);
        final expectedAllKeys = <String>{
          for (var i = 0; i < 6; i++) 'flt-A|${fltABaseMs + i * 1000}',
          for (var i = 0; i < 215; i++) 'flt-B|${fltBBaseMs + i * 1000}',
        };
        expect(truncatedKeySets.first, expectedAllKeys);

        // flt-B posted in strict oldest-first order in batches <= 100.
        expect(batchSizes, [100, 100, 15]);
        expect(batchSizes.every((s) => s > 0 && s <= 100), isTrue);
        expect(postedTimestamps, [
          for (var i = 0; i < 215; i++) fltBBaseMs + i * 1000,
        ]);
        expect(postedTimestamps.toSet(), hasLength(215));
        expect(
          authHeaders,
          everyElement('Bearer pers_tok_iso1_0123456789abcdef012345'),
        );

        // flt-A NEVER posted; preserved local-only on disk.
        expect(postedFlightIds.every((id) => id == 'flt-B'), isTrue);
        expect(postedFlightIds.contains('flt-A'), isFalse);

        // Cleanly dispose widget tree (stops periodic poll timer).
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        // Reopen brand-new disk store to verify persisted post-drain state.
        final reopened = FileFixUploadQueueStore(
          directoryProvider: () async => tempDir,
          accountBucket: 'acct_iso_1',
        );
        expect(
          await tester.runAsync(() => reopened.count(flightId: 'flt-B')),
          0,
        );
        expect(
          await tester.runAsync(() => reopened.count(flightId: 'flt-A')),
          6,
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets(
      'second cold start when native truncation failed does not double-queue flt-B or flt-A (dedup)',
      (tester) async {
        tester.platformDispatcher.localeTestValue = const Locale('es', 'CL');
        addTearDown(tester.platformDispatcher.clearLocaleTestValue);

        final tempDir = Directory.systemTemp.createTempSync('fv_iso_death_2_');
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        const fltBBaseMs = 1_760_150_000_000;
        const fltABaseMs = 1_760_040_000_000;
        final nativeEntries = <Map<String, dynamic>>[
          for (var i = 0; i < 5; i++)
            _nativeFixMap(i, flightId: 'flt-A', baseMs: fltABaseMs),
          for (var i = 0; i < 120; i++)
            _nativeFixMap(i, flightId: 'flt-B', baseMs: fltBBaseMs),
        ];

        var readCalls = 0;
        var failedTruncateCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(trackingChannel, (call) async {
          if (call.method == 'readNativeFixQueue') {
            readCalls++;
            return List<Map<String, dynamic>>.from(nativeEntries);
          }
          if (call.method == 'truncateNativeFixQueue') {
            // Simulate truncation failure: native queue keeps returning the
            // exact same entries across restarts.
            failedTruncateCalls++;
            throw PlatformException(
              code: 'io_error',
              message: 'simulated truncate failure',
            );
          }
          return null;
        });

        SharedPreferences.setMockInitialValues({
          PreferencesStore.permissionsOnboardingKey: true,
          PreferencesStore.activeFlightIdKey: 'flt-B',
          PreferencesStore.activeFlightModeKey: 'personal',
          PreferencesStore.activeFlightTailKey: 'CC-ISOB2',
        });

        var ingestOnline = false;
        var ingestAttempts = 0;
        final batchSizes = <int>[];
        final postedFlightIds = <String>[];
        final postedTimestamps = <int>[];

        FlightVisClient buildClient() => FlightVisClient(
              baseUrl: 'https://flight.heavenly.cl',
              httpClient: http_testing.MockClient((request) async {
                if (request.url.path == FlightVisApiPaths.accountMe) {
                  return http.Response(
                    jsonEncode({
                      'account': {
                        'id': 'acct-iso-2',
                        'email': 'iso2@example.cl',
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
                        {'id': 'flt-B', 'tail': 'CC-ISOB2', 'status': 'active'},
                      ],
                    }),
                    200,
                  );
                }
                if (request.method == 'POST' &&
                    request.url.path == FlightVisApiPaths.ingest) {
                  ingestAttempts++;
                  if (!ingestOnline) {
                    throw const SocketException('offline during cold start');
                  }
                  final body = jsonDecode(request.body) as Map<String, dynamic>;
                  final fixes = (body['fixes'] as List<dynamic>)
                      .cast<Map<String, dynamic>>();
                  batchSizes.add(fixes.length);
                  for (final f in fixes) {
                    postedFlightIds.add(f['flight_id'] as String);
                    postedTimestamps.add(f['t'] as int);
                  }
                  return http.Response(
                    jsonEncode({'ok': true, 'accepted': fixes.length}),
                    200,
                  );
                }
                return http.Response('{}', 200);
              }),
            );

        // --- Cold Start #1 (Dart store starts empty; ingest offline; truncate fails) ---
        final prefs1 = await PreferencesStore.open();
        final secure1 = _TestSecureStore(
          accountSessionId: 'acct-sess-iso2',
          personalDeviceToken: 'pers_tok_iso2_0123456789abcdef012345',
        );
        final store1 = FileFixUploadQueueStore(
          directoryProvider: () async => tempDir,
          accountBucket: 'acct_iso_2',
        );
        expect(_readDiskQueueCount(tempDir, 'acct_iso_2'), 0);

        await tester.pumpWidget(
          FlightVisApp(
            key: const ValueKey('cold-start-1'),
            repo: AppRepository(
              secure: secure1,
              prefs: prefs1,
              client: buildClient(),
            ),
            bindPlatformDeepLinks: false,
            stopStickyTrackerOnRestore: false,
            trackingService: TrackingService(
              tracker: _ControllableTracker(),
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: store1,
            permissions: _TestPermissions(),
            localFlightStore: InMemoryLocalFlightStore(),
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              failedTruncateCalls >= 1 &&
              ingestAttempts >= 1 &&
              _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-B') ==
                  120,
          maxTicks: 80,
          yieldRealIo: true,
        );

        // Simulate isolate death #2 before network comes back.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        expect(failedTruncateCalls, greaterThanOrEqualTo(1));
        expect(nativeEntries, hasLength(125));
        expect(
          _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-B'),
          120,
        );
        expect(
          _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-A'),
          5,
        );

        // --- Cold Start #2 (native queue STILL returns identical 125 entries!) ---
        final readCallsBefore2 = readCalls;
        final failedTruncatesBefore2 = failedTruncateCalls;
        final prefs2 = await PreferencesStore.open();
        final secure2 = _TestSecureStore(
          accountSessionId: 'acct-sess-iso2',
          personalDeviceToken: 'pers_tok_iso2_0123456789abcdef012345',
        );
        final store2 = FileFixUploadQueueStore(
          directoryProvider: () async => tempDir,
          accountBucket: 'acct_iso_2',
        );
        final tracker2 = _ControllableTracker();

        await tester.pumpWidget(
          FlightVisApp(
            key: const ValueKey('cold-start-2'),
            repo: AppRepository(
              secure: secure2,
              prefs: prefs2,
              client: buildClient(),
            ),
            bindPlatformDeepLinks: false,
            stopStickyTrackerOnRestore: false,
            trackingService: TrackingService(
              tracker: tracker2,
              fixSource: InMemoryLocalFixSource(),
            ),
            uploadQueue: store2,
            permissions: _TestPermissions(),
            localFlightStore: InMemoryLocalFlightStore(),
            tileProvider: FakeTileProvider(),
            enableMapPolling: false,
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              readCalls > readCallsBefore2 &&
              failedTruncateCalls > failedTruncatesBefore2 &&
              tracker2.started,
          maxTicks: 80,
          yieldRealIo: true,
        );

        // Critical dedup assertion: second cold start did NOT double-queue!
        expect(
          _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-B'),
          120,
        );
        expect(
          _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-A'),
          5,
        );
        expect(_readDiskQueueCount(tempDir, 'acct_iso_2'), 125);

        // Now bring network online and trigger reconnect -> exact 120 flt-B
        // fixes POST once, oldest-first, in <=100 batches; flt-A never POSTed.
        ingestOnline = true;
        tracker2.addLog('Network restored');
        await tester.pump(const Duration(seconds: 2));
        await _pumpUntil(
          tester,
          () =>
              postedTimestamps.length >= 120 &&
              _readDiskQueueCount(tempDir, 'acct_iso_2', flightId: 'flt-B') ==
                  0,
          maxTicks: 80,
          yieldRealIo: true,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        expect(batchSizes, [100, 20]);
        expect(postedTimestamps, [
          for (var i = 0; i < 120; i++) fltBBaseMs + i * 1000,
        ]);
        expect(postedFlightIds.every((id) => id == 'flt-B'), isTrue);
        expect(postedFlightIds.contains('flt-A'), isFalse);

        final reopenedFinal = FileFixUploadQueueStore(
          directoryProvider: () async => tempDir,
          accountBucket: 'acct_iso_2',
        );
        expect(
          await tester.runAsync(() => reopenedFinal.count(flightId: 'flt-B')),
          0,
        );
        expect(
          await tester.runAsync(() => reopenedFinal.count(flightId: 'flt-A')),
          5,
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  // ---------------------------------------------------------------------------
  // Group 2: RECONNECT
  // ---------------------------------------------------------------------------
  group('Reconnect after network outage (SocketException / 503)', () {
    testWidgets(
      'reconnect via Traccar ingestLogIndicatesNetworkRestored drains oldest-first with no duplicates to pending 0',
      (tester) async {
        expect(ingestLogIndicatesNetworkRestored('Network restored'), isTrue);

        SharedPreferences.setMockInitialValues({
          PreferencesStore.activeFlightIdKey: 'flt-B',
          PreferencesStore.activeFlightModeKey: 'personal',
        });
        final prefs = await PreferencesStore.open();
        final secure = _TestSecureStore(
          accountSessionId: 'acct-sess-rec1',
          personalDeviceToken: 'pers_tok_rec1_0123456789abcdef012345',
        );

        final queue = InMemoryFixUploadQueueStore();
        // Pre-seed older flt-A leftovers -> H-8 must keep them local-only.
        await queue.enqueueAll([
          _queuedFix(0, flightId: 'flt-A', baseMs: 1_760_000_000_000),
          _queuedFix(1, flightId: 'flt-A', baseMs: 1_760_000_000_000),
          _queuedFix(2, flightId: 'flt-A', baseMs: 1_760_000_000_000),
        ]);

        var networkOnline = false;
        var socketFailures = 0;
        var http503Failures = 0;
        final batchSizes = <int>[];
        final postedFlightIds = <String>[];
        final postedTimestamps = <int>[];

        final client = FlightVisClient(
          baseUrl: 'https://flight.heavenly.cl',
          accountSessionId: 'acct-sess-rec1',
          personalDeviceToken: 'pers_tok_rec1_0123456789abcdef012345',
          httpClient: http_testing.MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.ingest) {
              if (!networkOnline) {
                if (socketFailures == 0) {
                  socketFailures++;
                  throw const SocketException('Network is unreachable');
                }
                http503Failures++;
                return http.Response(
                  jsonEncode({'error': 'service unavailable'}),
                  503,
                );
              }
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final fixes =
                  (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
              batchSizes.add(fixes.length);
              for (final f in fixes) {
                postedFlightIds.add(f['flight_id'] as String);
                postedTimestamps.add(f['t'] as int);
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
        final tracker = _ControllableTracker();
        final fixSource = InMemoryLocalFixSource();

        await tester.pumpWidget(
          PilotAppShell(
            locale: const Locale('es', 'CL'),
            home: TrackingScreen(
              key: const ValueKey('reconnect-net-restored'),
              repo: repo,
              flightId: 'flt-B',
              tail: 'CC-RECB',
              flightMode: 'personal',
              tracking: TrackingService(
                tracker: tracker,
                fixSource: fixSource,
              ),
              uploadQueue: queue,
              onStopped: () {},
              tileProvider: FakeTileProvider(),
              enableMapPolling: false,
            ),
          ),
        );
        await _pumpUntil(tester, () => tracker.started);

        // 1) Fixes arrive right before Traccar logs SocketException failure.
        const baseMs = 1_760_200_000_000;
        for (var i = 0; i < 20; i++) {
          fixSource.emit(_localFix(i, baseMs: baseMs));
        }
        tracker.addLog('Upload error: SocketException');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 50));
        expect(await queue.count(flightId: 'flt-B'), 20);

        // 2) More fixes accumulate while degraded (including out-of-order and
        //    duplicate timestamps -> must order oldest-first & deduplicate).
        for (var i = 124; i >= 20; i--) {
          fixSource.emit(_localFix(i, baseMs: baseMs));
        }
        fixSource.emit(_localFix(5, baseMs: baseMs));
        fixSource.emit(_localFix(42, baseMs: baseMs));
        fixSource.emit(_localFix(124, baseMs: baseMs));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));

        expect(await queue.count(flightId: 'flt-B'), 125);
        expect(find.byKey(FlightVisTestKeys.trackingQueueBanner), findsOneWidget);

        // 3) Exercise failing ingest attempts during outage: SocketException
        //    then 503 -> fixes remain queued with zero loss / duplication.
        tracker.addLog('Network restored');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 50));
        expect(socketFailures, 1);

        // Advance FakeAsync past attempt-1 backoff (<=2s) so attempt 2 hits 503
        // deterministically for any jitter roll in [0, 1].
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 100));
        expect(http503Failures, greaterThanOrEqualTo(1));
        expect(postedTimestamps, isEmpty);
        expect(await queue.count(flightId: 'flt-B'), 125);

        // 4) Connectivity restored -> Traccar logs 'Network restored'.
        networkOnline = true;
        tracker.addLog('Network restored');
        await tester.pump(const Duration(seconds: 2));
        await _pumpUntil(tester, () => postedTimestamps.length >= 125);
        await tester.pump(const Duration(milliseconds: 50));

        // Assert full oldest-first drain, batches <= 100, zero duplicates,
        // flt-A untouched, and pending count == 0.
        expect(batchSizes, [100, 25]);
        expect(postedTimestamps, [
          for (var i = 0; i < 125; i++) baseMs + i * 1000,
        ]);
        expect(postedTimestamps.toSet(), hasLength(125));
        expect(postedFlightIds.every((id) => id == 'flt-B'), isTrue);
        expect(postedFlightIds.contains('flt-A'), isFalse);
        expect(await queue.count(flightId: 'flt-B'), 0);
        expect(await queue.count(flightId: 'flt-A'), 3);
        expect(find.byKey(FlightVisTestKeys.trackingQueueBanner), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets(
      'reconnect via successful live send (ingestLogIndicatesSuccess) wakes active backoff immediately and drains oldest-first to pending 0',
      (tester) async {
        expect(ingestLogIndicatesSuccess('Upload response 200'), isTrue);

        SharedPreferences.setMockInitialValues({
          PreferencesStore.activeFlightIdKey: 'flt-B',
          PreferencesStore.activeFlightModeKey: 'personal',
        });
        final prefs = await PreferencesStore.open();
        final secure = _TestSecureStore(
          accountSessionId: 'acct-sess-rec2',
          personalDeviceToken: 'pers_tok_rec2_0123456789abcdef012345',
        );

        final queue = InMemoryFixUploadQueueStore();
        await queue.enqueue(_queuedFix(0, flightId: 'flt-A'));

        var failCount = 0;
        var networkOnline = false;
        final batchSizes = <int>[];
        final postedFlightIds = <String>[];
        final postedTimestamps = <int>[];

        final client = FlightVisClient(
          baseUrl: 'https://flight.heavenly.cl',
          accountSessionId: 'acct-sess-rec2',
          personalDeviceToken: 'pers_tok_rec2_0123456789abcdef012345',
          httpClient: http_testing.MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.ingest) {
              if (!networkOnline) {
                failCount++;
                if (failCount.isOdd) {
                  throw const SocketException('Connection reset by peer');
                }
                return http.Response(
                  jsonEncode({'error': 'upstream 503'}),
                  503,
                );
              }
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final fixes =
                  (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
              batchSizes.add(fixes.length);
              for (final f in fixes) {
                postedFlightIds.add(f['flight_id'] as String);
                postedTimestamps.add(f['t'] as int);
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
        final tracker = _ControllableTracker();
        final fixSource = InMemoryLocalFixSource();

        // Deterministic full-jitter=1.0 worker: attempt 1 -> 2s, attempt 2 -> 4s,
        // attempt 3 -> 8s backoff sleep (uses cancellable default Timer backed
        // by FakeAsync).
        var clockNow = DateTime.utc(2026, 11, 27, 14, 0, 0);
        final worker = FixUploadWorker(
          queue: queue,
          activeFlightIdProvider: () =>
              prefs.activeFlightId() == 'flt-B' ? 'flt-B' : null,
          clock: () => clockNow,
          randomDouble: () => 1.0,
          uploadBatch: (batch, {required String flightMode}) =>
              client.ingestBatch(
            [for (final f in batch) f.toIngestJson()],
            deviceToken: client.deviceTokenForFlightMode(flightMode),
          ),
        );

        await tester.pumpWidget(
          PilotAppShell(
            locale: const Locale('es', 'CL'),
            home: TrackingScreen(
              key: const ValueKey('reconnect-live-200'),
              repo: repo,
              flightId: 'flt-B',
              tail: 'CC-REC2',
              flightMode: 'personal',
              tracking: TrackingService(
                tracker: tracker,
                fixSource: fixSource,
              ),
              uploadQueue: queue,
              uploadWorker: worker,
              onStopped: () {},
              tileProvider: FakeTileProvider(),
              enableMapPolling: false,
            ),
          ),
        );
        await _pumpUntil(tester, () => tracker.started);

        // Accumulate 110 flt-B fixes during outage (with duplicates).
        const baseMs = 1_760_300_000_000;
        for (var i = 0; i < 10; i++) {
          fixSource.emit(_localFix(i, baseMs: baseMs));
        }
        tracker.addLog('Upload response 503');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 50));

        for (var i = 109; i >= 10; i--) {
          fixSource.emit(_localFix(i, baseMs: baseMs));
        }
        fixSource.emit(_localFix(0, baseMs: baseMs));
        fixSource.emit(_localFix(55, baseMs: baseMs));
        await tester.pump(const Duration(milliseconds: 50));
        expect(await queue.count(flightId: 'flt-B'), 110);
        expect(worker.pendingCount, 110);

        // Trigger drain during outage -> fails 3 times (SocketException, 503,
        // SocketException) and enters an active 8-second backoff sleep!
        unawaited(worker.drain());
        await tester.pump();
        expect(failCount, 1);
        clockNow = clockNow.add(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        expect(failCount, 2);
        clockNow = clockNow.add(const Duration(seconds: 4));
        await tester.pump(const Duration(seconds: 4));
        expect(failCount, 3);
        expect(worker.isDraining, isTrue); // sleeping in 8s backoff!
        expect(postedTimestamps, isEmpty);

        // Connectivity returns -> Traccar reports a live 200 send.
        // Only advance 2s (for _tick poll) + 100ms — strictly LESS than the 8s
        // backoff sleep! Worker MUST wake immediately and drain everything.
        networkOnline = true;
        tracker.addLog('Upload response 200');
        clockNow = clockNow.add(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        await _pumpUntil(
          tester,
          () => postedTimestamps.length >= 110,
          maxTicks: 20,
          fakeStep: const Duration(milliseconds: 10),
        );

        expect(batchSizes, [100, 10]);
        expect(postedTimestamps, [
          for (var i = 0; i < 110; i++) baseMs + i * 1000,
        ]);
        expect(postedFlightIds.every((id) => id == 'flt-B'), isTrue);
        expect(postedFlightIds.contains('flt-A'), isFalse);
        expect(worker.pendingCount, 0);
        expect(await queue.count(flightId: 'flt-B'), 0);
        expect(await queue.count(flightId: 'flt-A'), 1);

        worker.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets(
      'reconnect via foreground resume imports background native fixes, dedups, and drains oldest-first to pending 0',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          PreferencesStore.activeFlightIdKey: 'flt-B',
          PreferencesStore.activeFlightModeKey: 'personal',
        });
        final prefs = await PreferencesStore.open();
        final secure = _TestSecureStore(
          accountSessionId: 'acct-sess-rec3',
          personalDeviceToken: 'pers_tok_rec3_0123456789abcdef012345',
        );

        final nativeEntries = <Map<String, dynamic>>[];
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

        final queue = InMemoryFixUploadQueueStore();
        await queue.enqueueAll([
          _queuedFix(0, flightId: 'flt-A', baseMs: 1_760_000_000_000),
          _queuedFix(1, flightId: 'flt-A', baseMs: 1_760_000_000_000),
        ]);

        var networkOnline = false;
        var outageErrors = 0;
        final batchSizes = <int>[];
        final postedFlightIds = <String>[];
        final postedTimestamps = <int>[];

        final client = FlightVisClient(
          baseUrl: 'https://flight.heavenly.cl',
          accountSessionId: 'acct-sess-rec3',
          personalDeviceToken: 'pers_tok_rec3_0123456789abcdef012345',
          httpClient: http_testing.MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path == FlightVisApiPaths.ingest) {
              if (!networkOnline) {
                outageErrors++;
                if (outageErrors == 1) {
                  throw const SocketException('No route to host');
                }
                return http.Response(jsonEncode({'error': 'unavailable'}), 503);
              }
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final fixes =
                  (body['fixes'] as List<dynamic>).cast<Map<String, dynamic>>();
              batchSizes.add(fixes.length);
              for (final f in fixes) {
                postedFlightIds.add(f['flight_id'] as String);
                postedTimestamps.add(f['t'] as int);
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
        final tracker = _ControllableTracker();
        final fixSource = InMemoryLocalFixSource();

        await tester.pumpWidget(
          PilotAppShell(
            locale: const Locale('es', 'CL'),
            home: TrackingScreen(
              key: const ValueKey('reconnect-fg-resume'),
              repo: repo,
              flightId: 'flt-B',
              tail: 'CC-REC3',
              flightMode: 'personal',
              tracking: TrackingService(
                tracker: tracker,
                fixSource: fixSource,
              ),
              uploadQueue: queue,
              onStopped: () {},
              tileProvider: FakeTileProvider(),
              enableMapPolling: false,
            ),
          ),
        );
        await _pumpUntil(tester, () => tracker.started);

        // Outage begins while foregrounded: 10 flt-B fixes accumulate.
        const baseMs = 1_760_400_000_000;
        for (var i = 0; i < 10; i++) {
          fixSource.emit(_localFix(i, baseMs: baseMs));
        }
        tracker.addLog('Upload error: SocketException');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 50));
        expect(await queue.count(flightId: 'flt-B'), 10);

        // Trigger failed upload attempts before backgrounding (SocketException
        // then 503 -> fixes stay queued intact).
        tracker.addLog('Network restored');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 100));
        expect(outageErrors, greaterThanOrEqualTo(2));

        // App moves to background -> pauses polling & worker.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();

        // While backgrounded offline, native queue captures 20 more flt-B fixes
        // (plus 2 overlapping timestamps from Dart and 2 older flt-A fixes).
        nativeEntries.addAll([
          _nativeFixMap(2, flightId: 'flt-A', baseMs: 1_760_000_000_000),
          _nativeFixMap(3, flightId: 'flt-A', baseMs: 1_760_000_000_000),
          _nativeFixMap(8, flightId: 'flt-B', baseMs: baseMs), // overlap dup
          _nativeFixMap(9, flightId: 'flt-B', baseMs: baseMs), // overlap dup
          for (var i = 29; i >= 10; i--)
            _nativeFixMap(i, flightId: 'flt-B', baseMs: baseMs),
        ]);

        // Connectivity restores and user returns to foreground.
        networkOnline = true;
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await _pumpUntil(
          tester,
          () => postedTimestamps.length >= 30 && nativeEntries.isEmpty,
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(truncateCalls, greaterThanOrEqualTo(1));
        expect(nativeEntries, isEmpty);
        expect(batchSizes, [30]);
        expect(postedTimestamps, [
          for (var i = 0; i < 30; i++) baseMs + i * 1000,
        ]);
        expect(postedTimestamps.toSet(), hasLength(30));
        expect(postedFlightIds.every((id) => id == 'flt-B'), isTrue);
        expect(postedFlightIds.contains('flt-A'), isFalse);
        expect(await queue.count(flightId: 'flt-B'), 0);
        expect(await queue.count(flightId: 'flt-A'), 4);
        expect(find.byKey(FlightVisTestKeys.trackingQueueBanner), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
