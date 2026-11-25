import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flight_vis/api/flight_vis_api_paths.dart';
import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/app_shell.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/screens/home_hub_screen.dart';
import 'package:flight_vis/screens/permissions_onboarding_screen.dart';
import 'package:flight_vis/screens/tail_picker_screen.dart';
import 'package:flight_vis/services/app_repository.dart';
import 'package:flight_vis/services/flight_permissions.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/storage/secure_store.dart';
import 'package:flight_vis/widgets/permission_warning_card.dart';

class _FakeSecure extends SecureStore {
  @override
  Future<String?> readDeviceToken() async => '01234567890123456789012345678901';
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

class _FakePermissions extends FlightPermissionsClient {
  _FakePermissions({
    this.fineResult = true,
    this.backgroundResult = true,
    this.notifResult = true,
    this.batteryResult = true,
    FlightPermissionStatus? status,
  }) : status = status ??
            const FlightPermissionStatus(
              fineLocationGranted: true,
              backgroundLocationGranted: true,
              notificationsGranted: true,
              batteryUnrestricted: true,
            );

  bool fineResult;
  bool backgroundResult;
  bool notifResult;
  bool batteryResult;
  FlightPermissionStatus status;

  int checkCalls = 0;
  int openSettingsCalls = 0;
  final List<PermissionGap> openedGaps = [];

  @override
  Future<FlightPermissionStatus> check() async {
    checkCalls++;
    return status;
  }

  @override
  Future<bool> requestFineLocation() async => fineResult;

  @override
  Future<bool> requestBackgroundLocation() async => backgroundResult;

  @override
  Future<bool> requestNotifications() async => notifResult;

  @override
  Future<bool> requestBatteryExemption() async => batteryResult;

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    return true;
  }

  @override
  Future<void> openGapSettings(PermissionGap gap) async {
    openedGaps.add(gap);
  }
}

Future<AppRepository> _buildRepo({http.Client? httpClient}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await PreferencesStore.open();
  return AppRepository(
    secure: _FakeSecure(),
    prefs: prefs,
    client: FlightVisClient(
      baseUrl: prefs.baseUrl(),
      httpClient: httpClient,
      deviceToken: '01234567890123456789012345678901',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PermissionsOnboardingScreen', () {
    testWidgets('denied step does not advance silently and shows settings + skip options', (tester) async {
      final repo = await _buildRepo();
      final perms = _FakePermissions(fineResult: false);

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: PermissionsOnboardingScreen(
            repo: repo,
            onComplete: () {},
            permissions: perms,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Step 1: Intro
      expect(find.text('Paso 1 de 6'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();

      // Step 2: Fine location
      expect(find.text('Paso 2 de 6'), findsOneWidget);
      expect(find.text('Ubicación precisa'), findsOneWidget);

      // Request fine location -> denied; must STAY on Step 2 and show inline guidance.
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();

      expect(find.text('Paso 2 de 6'), findsOneWidget);
      expect(find.text('Ubicación precisa'), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.permissionsDeniedMessage), findsOneWidget);
      expect(find.text('Abrir ajustes'), findsOneWidget);
      expect(find.text('Continuar de todos modos'), findsOneWidget);

      // Tapping "Abrir ajustes" delegates to the permission abstraction.
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsOpenSettings));
      await tester.pumpAndSettle();
      expect(perms.openSettingsCalls, 1);

      // Returning from settings after user granted permission advances automatically.
      perms.status = const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: false,
        notificationsGranted: false,
        batteryUnrestricted: false,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('Paso 3 de 6'), findsOneWidget);
      expect(find.text('Permitir todo el tiempo'), findsOneWidget);
      expect(find.byKey(FlightVisTestKeys.permissionsDeniedMessage), findsNothing);
    });

    testWidgets('done step shows distinct ready copy when all permissions are granted', (tester) async {
      final repo = await _buildRepo();
      final perms = _FakePermissions();
      var completed = false;

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: PermissionsOnboardingScreen(
            repo: repo,
            onComplete: () => completed = true,
            permissions: perms,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Advance intro -> fine -> background -> notifications -> battery -> done (5 taps).
      for (var step = 1; step <= 5; step++) {
        expect(find.text('Paso $step de 6'), findsOneWidget);
        await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
        await tester.pumpAndSettle();
      }

      // Final step uses distinct done copy, NOT the intro title/body.
      expect(find.text('Paso 6 de 6'), findsOneWidget);
      expect(find.text('Permisos listos'), findsOneWidget);
      expect(find.text('Ya puedes registrar tu vuelo con el QR del club.'), findsOneWidget);
      expect(
        find.textContaining('Para transmitir tu posición durante el vuelo'),
        findsNothing,
      );

      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(repo.prefs.permissionsOnboardingComplete(), isTrue);
    });

    testWidgets('done step lists missing permissions when some steps were skipped after denial', (tester) async {
      final repo = await _buildRepo();
      final perms = _FakePermissions(
        fineResult: true,
        backgroundResult: false,
        notifResult: true,
        batteryResult: false,
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: PermissionsOnboardingScreen(
            repo: repo,
            onComplete: () {},
            permissions: perms,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Intro -> Fine (granted) -> Background (denied -> skip) -> Notif (granted) -> Battery (denied -> skip) -> Done
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();

      // Background denied -> stays on step 3 -> skip
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();
      expect(find.text('Paso 3 de 6'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsSkip));
      await tester.pumpAndSettle();

      // Notifications granted
      expect(find.text('Paso 4 de 6'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();

      // Battery denied -> stays on step 5 -> skip
      expect(find.text('Paso 5 de 6'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsPrimary));
      await tester.pumpAndSettle();
      expect(find.text('Paso 5 de 6'), findsOneWidget);
      await tester.tap(find.byKey(FlightVisTestKeys.permissionsSkip));
      await tester.pumpAndSettle();

      // Done step reports which permissions are missing instead of "Permisos listos".
      expect(find.text('Paso 6 de 6'), findsOneWidget);
      expect(find.text('Permisos listos'), findsNothing);
      expect(find.text('Faltan algunos permisos'), findsOneWidget);
      expect(find.textContaining('Ubicación en segundo plano'), findsOneWidget);
      expect(find.textContaining('Batería sin restricciones'), findsOneWidget);
    });
  });

  group('PermissionWarningCard wiring', () {
    testWidgets('HomeHubScreen shows warning card when background location or battery is missing and refreshes on resume', (tester) async {
      final repo = await _buildRepo();
      final perms = _FakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: false,
          notificationsGranted: true,
          batteryUnrestricted: true,
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
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PermissionWarningCard), findsOneWidget);
      expect(find.text('Faltan permisos para transmitir'), findsOneWidget);
      expect(find.textContaining('Permitir todo el tiempo'), findsOneWidget);

      // Grant permissions and simulate app resume -> card disappears.
      perms.status = const FlightPermissionStatus(
        fineLocationGranted: true,
        backgroundLocationGranted: true,
        notificationsGranted: true,
        batteryUnrestricted: true,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(perms.checkCalls, greaterThanOrEqualTo(2));
      expect(find.byType(PermissionWarningCard), findsNothing);
    });

    testWidgets('HomeHubScreen shows warning card when battery exemption is missing', (tester) async {
      final repo = await _buildRepo();
      final perms = _FakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: true,
          notificationsGranted: true,
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
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PermissionWarningCard), findsOneWidget);
      expect(find.textContaining('optimización de batería'), findsOneWidget);
    });

    testWidgets('TailPickerScreen shows warning card when permission missing and refreshes on resume', (tester) async {
      final repo = await _buildRepo(
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == FlightVisApiPaths.meTails) {
            return http.Response(
              jsonEncode({
                'tails': [
                  {'id': 'a1', 'tail': 'CC-ABC', 'type_code': 'C172'},
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
      final perms = _FakePermissions(
        status: const FlightPermissionStatus(
          fineLocationGranted: true,
          backgroundLocationGranted: false,
          notificationsGranted: true,
          batteryUnrestricted: false,
        ),
      );

      await tester.pumpWidget(
        PilotAppShell(
          locale: const Locale('es', 'CL'),
          home: TailPickerScreen(
            repo: repo,
            onFlightStarted: (_, _) {},
            permissions: perms,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PermissionWarningCard), findsOneWidget);
      expect(find.text('Faltan permisos para transmitir'), findsOneWidget);

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
