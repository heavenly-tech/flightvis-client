import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/main.dart' as app;

import 'integration_helpers.dart';

const _checkinUrl =
    'https://flight.heavenly.cl/c/demo-club/q/v1.club1.999999.abcdef0123456789abcdef0123456789';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'guest-first flow screenshots (ES)',
    (tester) async {
      ciLog('screenshots: start capture=${AppConfig.captureScreenshots}');
      expect(AppConfig.captureScreenshots, isTrue);
      app.main();
      await pumpFrames(tester, total: const Duration(seconds: 4));

      await advancePermissionsOnboardingIfNeeded(tester);
      await waitForFound(tester, find.text('Iniciar sesión'), timeout: const Duration(seconds: 25));
      await saveEmulatorScreenshot(binding, '01-guest-hub');

      await tapWhenFound(tester, find.text('Iniciar sesión'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Continuar sin iniciar sesión'), timeout: const Duration(seconds: 20));
      await saveEmulatorScreenshot(binding, '02-login-options');

      await tapWhenFound(tester, find.text('Continuar sin iniciar sesión'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Check-in club'), timeout: const Duration(seconds: 25));
      await saveEmulatorScreenshot(binding, '03-hub-after-permissions');

      await tapWhenFound(tester, find.text('Check-in club'), timeout: const Duration(seconds: 20));
      await waitForFound(
        tester,
        find.widgetWithText(TextField, 'O pegue el token de check-in'),
        timeout: const Duration(seconds: 25),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'O pegue el token de check-in'),
        _checkinUrl,
      );
      await tapWhenFound(tester, find.text('Enviar token'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Continuar'), timeout: const Duration(seconds: 30));
      await saveEmulatorScreenshot(binding, '04-checkin-success');

      await tapWhenFound(tester, find.text('Continuar'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Detalles del vuelo'), timeout: const Duration(seconds: 25));
      await tapWhenFound(tester, find.text('Detalles del vuelo'), timeout: const Duration(seconds: 20));
      await pumpFrames(tester, total: const Duration(seconds: 2));
      await saveEmulatorScreenshot(binding, '05-flight-details');

      await tapWhenFound(tester, find.text('Comenzar tracking'), timeout: const Duration(seconds: 25));
      await waitForFound(tester, find.text('Finalizar tracking'), timeout: const Duration(seconds: 30));
      await saveEmulatorScreenshot(binding, '06-broadcasting');

      expect(find.text('Finalizar tracking'), findsOneWidget);
      ciLog('screenshots: done');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}