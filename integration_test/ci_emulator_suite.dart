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

/// One [testWidgets] = one process / one `app.main()` (relaunching the app between
/// tests often hangs on the Flutter integration driver after APK install).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CI emulator suite: mock, guest flow, deep link',
    (tester) async {
      ciLog('suite: start compile baseUrl=${AppConfig.defaultBaseUrl} screenshot=${AppConfig.screenshotTest}');
      expect(AppConfig.defaultBaseUrl, 'http://10.0.2.2:18080');
      expect(AppConfig.screenshotTest, isTrue);

      final healthUri = Uri.parse('${AppConfig.defaultBaseUrl}/api/ci-health');
      ciLog('suite: smoke GET $healthUri');
      final health = await http.get(healthUri).timeout(const Duration(seconds: 15));
      expect(health.statusCode, 200, reason: health.body);
      ciLog('suite: smoke OK');

      ciLog('suite: app.main');
      app.main();
      await pumpFrames(tester, total: const Duration(seconds: 4));

      await advancePermissionsOnboardingIfNeeded(tester);
      await waitForFound(tester, find.text('Iniciar sesión'), label: 'es-CL hub', timeout: const Duration(seconds: 25));
      ciLog('suite: hub es-CL');

      await tapWhenFound(tester, find.text('Iniciar sesión'), label: 'login', timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Continuar sin iniciar sesión'), timeout: const Duration(seconds: 20));
      await tapWhenFound(tester, find.text('Continuar sin iniciar sesión'), label: 'guest', timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Registro en el club'), timeout: const Duration(seconds: 25));
      ciLog('suite: guest hub');

      await tapWhenFound(tester, find.text('Registro en el club'), label: 'check-in', timeout: const Duration(seconds: 20));
      await tapWhenFound(
        tester,
        find.text('¿No funciona la cámara? Pegar código manual'),
        label: 'manual entry',
        timeout: const Duration(seconds: 20),
      );
      await waitForFound(
        tester,
        find.widgetWithText(TextField, 'Pega el código de registro'),
        timeout: const Duration(seconds: 25),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Pega el código de registro'),
        _checkinUrl,
      );
      await tapWhenFound(tester, find.text('Enviar código'), timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Continuar'), label: 'check-in ok', timeout: const Duration(seconds: 30));
      ciLog('suite: check-in OK');

      await tapWhenFound(tester, find.text('Continuar'), label: 'continue to tail picker', timeout: const Duration(seconds: 20));
      await waitForFound(tester, find.text('Detalles del vuelo'), timeout: const Duration(seconds: 25));

      await pumpFrames(tester, total: const Duration(seconds: 2));
      await tapWhenFound(tester, find.text('Comenzar vuelo'), timeout: const Duration(seconds: 25));
      await waitForFound(tester, find.text('Finalizar seguimiento'), timeout: const Duration(seconds: 30));
      expect(find.text('Finalizar seguimiento'), findsOneWidget);
      ciLog('suite: tracking OK');

      await DeepLinkTestHooks.dispatch(
        const CheckinDeepLink(
          clubSlug: 'demo-club',
          token: 'v1.club1.999999.abcdef0123456789abcdef0123456789',
        ),
      );
      await pumpFrames(tester, total: const Duration(seconds: 3));
      expect(find.text('Registro en el club'), findsWidgets);
      expect(find.textContaining('v1.club1'), findsNothing);
      ciLog('suite: deep link OK — done');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}