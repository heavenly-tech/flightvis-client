import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/main.dart' as app;

import 'integration_helpers.dart';

const _checkinUrl =
    'https://flight.heavenly.cl/c/demo-club/q/v1.club1.999999.abcdef0123456789abcdef0123456789';

Future<void> saveScreenshot(IntegrationTestWidgetsFlutterBinding binding, String name) async {
  await binding.convertFlutterSurfaceToImage();
  final bytes = await binding.takeScreenshot(name);
  if (bytes.isEmpty) return;
  final dir = Directory('/sdcard/Download/flightvis-emulator');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  File('${dir.path}/$name.png').writeAsBytesSync(bytes);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'guest-first flow with login options (ES)',
    (tester) async {
      ciLog('flow: start');
      expect(AppConfig.screenshotTest, isTrue);
      app.main();
      await pumpFrames(tester, total: const Duration(seconds: 4));

      await advancePermissionsOnboardingIfNeeded(tester);

      await waitForFound(tester, find.text('Iniciar sesión'), label: 'es-CL hub (Iniciar sesión)');
      ciLog('flow: es-CL hub confirmed');

      await saveScreenshot(binding, '01-guest-hub');

      await tapWhenFound(tester, find.text('Iniciar sesión'), label: 'login button');
      await waitForFound(tester, find.text('Continuar sin iniciar sesión'), label: 'login options');
      ciLog('flow: login options');

      await saveScreenshot(binding, '02-login-options');

      await tapWhenFound(tester, find.text('Continuar sin iniciar sesión'), label: 'continue as guest');
      await waitForFound(tester, find.text('Check-in club'), label: 'hub after guest');

      await saveScreenshot(binding, '03-hub-after-permissions');

      await tapWhenFound(tester, find.text('Check-in club'), label: 'open check-in');
      await waitForFound(
        tester,
        find.widgetWithText(TextField, 'O pegue el token de check-in'),
        label: 'check-in paste field',
      );
      ciLog('flow: check-in screen');

      await tester.enterText(
        find.widgetWithText(TextField, 'O pegue el token de check-in'),
        _checkinUrl,
      );
      await tapWhenFound(tester, find.text('Enviar token'), label: 'submit check-in');
      await waitForFound(tester, find.text('Continuar'), label: 'check-in success');
      ciLog('flow: check-in OK');

      await saveScreenshot(binding, '04-checkin-success');

      await tapWhenFound(tester, find.text('Continuar'), label: 'leave check-in');
      await waitForFound(tester, find.text('Detalles del vuelo'), label: 'hub with flight details');

      await tapWhenFound(tester, find.text('Detalles del vuelo'), label: 'flight details');
      await pumpFrames(tester, total: const Duration(seconds: 2));
      ciLog('flow: flight details');

      await saveScreenshot(binding, '05-flight-details');

      await tapWhenFound(tester, find.text('Comenzar tracking'), label: 'start tracking');
      await waitForFound(tester, find.text('Finalizar tracking'), label: 'tracking screen');
      ciLog('flow: tracking screen');

      await saveScreenshot(binding, '06-broadcasting');

      expect(find.text('Finalizar tracking'), findsOneWidget);
      ciLog('flow: done');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}