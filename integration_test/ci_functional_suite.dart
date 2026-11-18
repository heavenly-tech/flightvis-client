import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/main.dart' as app;
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import 'integration_helpers.dart';

const _checkinUrl =
    'https://flight.heavenly.cl/c/demo-club/q/v1.club1.999999.abcdef0123456789abcdef0123456789';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'emulator smoke: compiled defines and mock health',
    (_) async {
      ciLog('functional-smoke: baseUrl=${AppConfig.defaultBaseUrl} screenshot=${AppConfig.screenshotTest}');
      expect(AppConfig.defaultBaseUrl, 'http://10.0.2.2:18080');
      expect(AppConfig.screenshotTest, isTrue);
      expect(AppConfig.captureScreenshots, isFalse);

      final uri = Uri.parse('${AppConfig.defaultBaseUrl}/api/ci-health');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      expect(response.statusCode, 200, reason: response.body);
      ciLog('functional-smoke: OK');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  testWidgets(
    'guest check-in, tracking start/stop, deep link (single app session)',
    (tester) async {
      ciLog('functional-flow: start');
      app.main();
      await pumpFrames(tester, total: const Duration(seconds: 4));

      await advancePermissionsOnboardingIfNeeded(tester);
      await waitForFound(tester, find.text('Iniciar sesión'), label: 'es-CL hub', timeout: const Duration(seconds: 25));

      await tapWhenFound(tester, find.text('Iniciar sesión'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Continuar sin iniciar sesión'), timeout: const Duration(seconds: 20));
      await tapWhenFound(tester, find.text('Continuar sin iniciar sesión'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Check-in club'), timeout: const Duration(seconds: 25));

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
      await waitForFound(tester, find.text('Continuar'), label: 'check-in ok', timeout: const Duration(seconds: 30));
      ciLog('functional-flow: check-in OK');

      await tapWhenFound(tester, find.text('Continuar'), label: 'pop check-in', timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Detalles del vuelo'), timeout: const Duration(seconds: 25));
      await tapWhenFound(tester, find.text('Detalles del vuelo'), timeout: const Duration(seconds: 20));
      await tapWhenFound(tester, find.text('Comenzar tracking'), timeout: const Duration(seconds: 25));
      await waitForFound(tester, find.text('Finalizar tracking'), timeout: const Duration(seconds: 30));
      ciLog('functional-flow: tracking started');

      await tapWhenFound(tester, find.text('Finalizar tracking'), timeout: const Duration(seconds: 20));
      await pumpFrames(tester, total: const Duration(seconds: 2));
      await waitForFound(tester, find.text('Check-in club'), label: 'hub after stop', timeout: const Duration(seconds: 30));
      ciLog('functional-flow: tracking stopped');

      await DeepLinkTestHooks.dispatch(
        const CheckinDeepLink(
          clubSlug: 'demo-club',
          token: 'v1.club1.999999.abcdef0123456789abcdef0123456789',
        ),
      );
      await pumpFrames(tester, total: const Duration(seconds: 3));
      expect(find.text('Check-in club'), findsWidgets);
      expect(find.textContaining('v1.club1'), findsNothing);
      ciLog('functional-flow: deep link OK — done');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}