import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/native_fix_queue.dart';
import 'package:flight_vis/storage/fix_upload_queue.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';

class _MemSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => null;
  @override
  Future<String?> readSessionId() async => null;
  @override
  Future<void> writeDeviceToken(String token) async {}
  @override
  Future<void> clearDeviceToken() async {}
  @override
  Future<void> writeSessionId(String sessionId) async {}
  @override
  Future<void> clearSessionId() async {}
  @override
  Future<void> clearAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('L-93 auth reset native bridge', () {
    const channel = MethodChannel('cl.heavenly.flightvis/tracking');
    final log = <String, dynamic>{};

    setUp(() {
      log.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log[call.method] = call.arguments;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('clearAll invokes clearNativeFixQueue and clearActiveNativeFlight',
        () async {
      const bridge = NativeFixQueueBridge(channel: channel);
      await bridge.clearAll();
      expect(log.containsKey('clearActiveNativeFlight'), isTrue);
      expect(log.containsKey('clearNativeFixQueue'), isTrue);
    });

    test('same-account re-login does not invoke L-93 hook', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferencesStore.lastSignedInAccountIdKey: 'acct-1',
      });
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _MemSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      var hookCalls = 0;
      repo.onAccountSwitchedForL93 = () async => hookCalls++;
      final changed =
          await repo.clearPersonalDeviceTokenIfAccountChanged('acct-1');
      expect(changed, isFalse);
      expect(hookCalls, 0);
    });

    test('account switch invokes upload queue clear via hook', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PreferencesStore.lastSignedInAccountIdKey: 'acct-old',
      });
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _MemSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: 'https://example.test'),
      );
      final queue = InMemoryFixUploadQueueStore();
      await queue.enqueue(
        const QueuedFixInput(
          flightId: 'f1',
          tMs: 1,
          lat: -33.0,
          lon: -70.0,
        ),
      );
      repo.onAccountSwitchedForL93 = () async {
        await queue.clear();
        await const NativeFixQueueBridge(channel: channel).clearAll();
      };
      final changed =
          await repo.clearPersonalDeviceTokenIfAccountChanged('acct-new');
      expect(changed, isTrue);
      expect(await queue.count(), 0);
      expect(log.containsKey('clearNativeFixQueue'), isTrue);
    });
  });
}