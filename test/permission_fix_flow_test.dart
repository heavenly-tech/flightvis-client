import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/services/permission_fix_flow.dart';
import 'package:flight_vis/storage/local_flight_store.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/widgets/permission_warning_card.dart';

class _FakeSecure extends SecureStore {
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

class _StepFakePermissions extends FlightPermissionsClient {
  _StepFakePermissions({
    required this.status,
    this.onOpenGap,
  });

  FlightPermissionStatus status;
  void Function(PermissionGap gap)? onOpenGap;
  final List<PermissionGap> openedGaps = [];
  int checkCalls = 0;

  @override
  Future<FlightPermissionStatus> check() async {
    checkCalls++;
    return status;
  }

  @override
  Future<bool> requestFineLocation() async => status.fineLocationGranted;

  @override
  Future<bool> requestBackgroundLocation() async =>
      status.backgroundLocationGranted;

  @override
  Future<bool> requestNotifications() async => status.notificationsGranted;

  @override
  Future<bool> requestBatteryExemption() async => status.batteryUnrestricted;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<void> openGapSettings(PermissionGap gap) async {
    openedGaps.add(gap);
    onOpenGap?.call(gap);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PermissionFixFlow unit tests', () {
    test('nextGapToFix returns gaps in exact canonical order', () {
      expect(
        PermissionFixFlow.nextGapToFix(
          const FlightPermissionStatus(
            fineLocationGranted: false,
            backgroundLocationGranted: false,
            notificationsGranted: false,
            batteryUnrestricted: false,
          ),
        ),
        PermissionGap.fineLocation,
      );
      expect(
        PermissionFixFlow.nextGapToFix(
          const FlightPermissionStatus(
            fineLocationGranted: true,
            backgroundLocationGranted: false,
            notificationsGranted: false,
            batteryUnrestricted: false,
          ),
        ),
        PermissionGap.backgroundLocation,
      );
      expect(
        PermissionFixFlow.nextGapToFix(
          const FlightPermissionStatus(
            fineLocationGranted: true,
            backgroundLocationGranted: true,
            notificationsGranted: false,
            batteryUnrestricted: false,
          ),
        ),
        PermissionGap.notifications,
      );
      expect(
        PermissionFixFlow.nextGapToFix(
          const FlightPermissionStatus(
            fineLocationGranted: true,
            backgroundLocationGranted: true,
            notificationsGranted: true,
            batteryUnrestricted: false,
          ),
        ),
        PermissionGap.battery,
      );
      expect(
        PermissionFixFlow.nextGapToFix(
          const FlightPermissionStatus(
            fineLocationGranted: true,
            backgroundLocationGranted: true,
            notificationsGranted: true,
            batteryUnrestricted: true,
          ),
        ),
        isNull,
      );
    });

    test('walks through fine -> background -> notifications -> battery and tracks stuck OEM hint', () async {
      late _StepFakePermissions perms;
      var grantOnOpen = false;
      perms = _StepFakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: false,
          backgroundLocationGranted: false,
          notificationsGranted: false,
          batteryUnrestricted: false,
        ),
        onOpenGap: (gap) {
          if (!grantOnOpen) return;
          perms.status = FlightPermissionStatus(
            fineLocationGranted:
                gap == PermissionGap.fineLocation || perms.status.fineLocationGranted,
            backgroundLocationGranted: gap == PermissionGap.backgroundLocation ||
                perms.status.backgroundLocationGranted,
            notificationsGranted: gap == PermissionGap.notifications ||
                perms.status.notificationsGranted,
            batteryUnrestricted:
                gap == PermissionGap.battery || perms.status.batteryUnrestricted,
          );
        },
      );

      final flow = PermissionFixFlow(client: perms);

      // Attempt fine without granting -> marks fineLocation as stuck.
      var s = await flow.fixNext(perms.status);
      expect(perms.openedGaps, [PermissionGap.fineLocation]);
      expect(flow.stuckGap, PermissionGap.fineLocation);

      // Now grant each step in order.
      grantOnOpen = true;
      s = await flow.fixNext(s);
      expect(flow.stuckGap, isNull);
      s = await flow.fixNext(s);
      s = await flow.fixNext(s);
      s = await flow.fixNext(s);

      expect(perms.openedGaps, [
        PermissionGap.fineLocation,
        PermissionGap.fineLocation,
        PermissionGap.backgroundLocation,
        PermissionGap.notifications,
        PermissionGap.battery,
      ]);
      expect(s.allGranted, isTrue);
      expect(flow.stuckGap, isNull);
    });
  });

  group('PlatformFlightPermissions native battery channel', () {
    const channel = MethodChannel('cl.heavenly.flightvis/tracking');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('openGapSettings(battery) invokes native openBatteryOptimizationSettings', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'openBatteryOptimizationSettings') {
          return 'request_ignore_battery_optimizations';
        }
        return null;
      });

      const perms = PlatformFlightPermissions(
        trackingChannel: channel,
        forceAndroid: true,
      );
      await perms.openGapSettings(PermissionGap.battery);
      expect(calls, ['openBatteryOptimizationSettings']);
    });

    test('requestBatteryExemption invokes native openBatteryOptimizationSettings then checks isIgnoringBatteryOptimizations', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'openBatteryOptimizationSettings') {
          return 'request_ignore_battery_optimizations';
        }
        if (call.method == 'isIgnoringBatteryOptimizations') {
          return true;
        }
        return null;
      });

      const perms = PlatformFlightPermissions(
        trackingChannel: channel,
        forceAndroid: true,
      );
      final granted = await perms.requestBatteryExemption();
      expect(granted, isTrue);
      expect(calls, [
        'openBatteryOptimizationSettings',
        'isIgnoringBatteryOptimizations',
      ]);
    });
  });

  group('PermissionWarningCard single-button walk-through, OEM hints, and resume re-check', () {
    testWidgets('shows ONE Corregir button, walks through gaps, shows OEM hint when stuck, and clears on resume', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await PreferencesStore.open();
      final repo = AppRepository(
        secure: _FakeSecure(),
        prefs: prefs,
        client: FlightVisClient(baseUrl: prefs.baseUrl()),
      );

      late _StepFakePermissions perms;
      perms = _StepFakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: false,
          notificationsGranted: false,
          batteryUnrestricted: false,
        ),
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: HomeHubScreen(
            repo: repo,
            onStartFlight: (_, _) {},
            onRequestLogin: () {},
            onLogout: () {},
            permissions: perms,
            localFlightStore: InMemoryLocalFlightStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Lists all 3 missing gaps, but renders ONLY ONE "Corregir" button.
      expect(find.byType(PermissionWarningCard), findsOneWidget);
      expect(find.text('Corregir'), findsOneWidget);
      expect(find.textContaining('Permitir todo el tiempo'), findsOneWidget);
      expect(find.textContaining('notificaciones'), findsOneWidget);
      expect(find.textContaining('optimización de batería'), findsOneWidget);

      // Tap Corregir while background stays missing -> shows background OEM hint.
      await tester.tap(find.byKey(FlightVisTestKeys.permissionWarningFix));
      await tester.pumpAndSettle();
      expect(perms.openedGaps, [PermissionGap.backgroundLocation]);
      expect(find.byKey(FlightVisTestKeys.permissionWarningHint), findsOneWidget);
      expect(find.text('Elige «Permitir todo el tiempo» en Ubicación.'), findsOneWidget);

      // User grants background and notifications and returns to app (resume).
      perms.status = const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: false,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // Hint cleared because background was resolved; battery still shown.
      expect(find.byKey(FlightVisTestKeys.permissionWarningHint), findsNothing);
      expect(find.byType(PermissionWarningCard), findsOneWidget);

      // Tap Corregir -> now targets battery; if still missing shows battery OEM hint.
      await tester.tap(find.byKey(FlightVisTestKeys.permissionWarningFix));
      await tester.pumpAndSettle();
      expect(perms.openedGaps, [
        PermissionGap.backgroundLocation,
        PermissionGap.battery,
      ]);
      expect(
        find.text(
          'Si no aparece, abre Ajustes > Apps > flight_vis > Batería y elige «Sin restricciones».',
        ),
        findsOneWidget,
      );

      // User accepts battery exemption and resumes -> banner clears without restart!
      perms.status = const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.byType(PermissionWarningCard), findsNothing);
    });
  });
}
