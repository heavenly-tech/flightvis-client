import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/ci_test_keys.dart';
import 'package:flight_vis/main.dart' as app;
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import 'integration_helpers.dart';

const _checkinUrl =
    'https://flight.heavenly.cl/c/demo-club/q/v1.club1.999999.abcdef0123456789abcdef0123456789';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
      try {
        app.main();
        await pumpFrames(tester, total: const Duration(seconds: 3));

        await ciStep(tester, 'reach hub', () async {
          await ensureOnPilotHub(tester, timeout: const Duration(seconds: 90));
        }, timeout: const Duration(seconds: 95));

        await ciStep(tester, 'guest login path', () async {
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.hubSignIn),
            label: 'hub sign in',
            timeout: const Duration(seconds: 45),
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.loginGuest),
            label: 'continue as guest',
            timeout: const Duration(seconds: 45),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.hub),
            label: 'hub',
            timeout: const Duration(seconds: 45),
          );
        }, timeout: const Duration(seconds: 120));

        await ciStep(tester, 'club check-in', () async {
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.hubCheckIn),
            label: 'hub check-in',
            timeout: const Duration(seconds: 45),
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinManualEntry),
            label: 'check-in manual entry',
            timeout: const Duration(seconds: 45),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinPasteField),
            label: 'check-in paste field',
            timeout: const Duration(seconds: 45),
          );
          await tester.enterText(
            find.byKey(FlightVisTestKeys.checkinPasteField),
            _checkinUrl,
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinPasteSubmit),
            label: 'submit code',
            timeout: const Duration(seconds: 45),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinContinue),
            label: 'check-in ok',
            timeout: const Duration(seconds: 60),
          );
        }, timeout: const Duration(seconds: 120));
        ciLog('functional-flow: check-in OK');

        await ciStep(tester, 'continue check-in to tail picker', () async {
          await activateCheckinContinue(tester);
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.tailPicker),
            label: 'tail picker',
            timeout: const Duration(seconds: 90),
          );
        }, timeout: const Duration(seconds: 90));

        await ciStep(tester, 'start tracking', () async {
          await waitForAbsent(
            tester,
            find.byType(CircularProgressIndicator),
            label: 'tail list loading',
            timeout: const Duration(seconds: 45),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.tailStart),
            label: 'tail start ready',
            timeout: const Duration(seconds: 45),
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.tailStart),
            label: 'start tracking',
            timeout: const Duration(seconds: 45),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.trackingStop),
            label: 'tracking stop control',
            timeout: const Duration(seconds: 60),
          );
        }, timeout: const Duration(seconds: 120));
        ciLog('functional-flow: tracking started');

        await ciStep(tester, 'stop tracking', () async {
          await stopTrackingAndReturnToHub(tester);
        }, timeout: const Duration(seconds: 120));
        ciLog('functional-flow: tracking stopped');

        await ciStep(tester, 'deep link dispatch', () async {
          await DeepLinkTestHooks.dispatch(
            const CheckinDeepLink(
              clubSlug: 'demo-club',
              token: 'v1.club1.999999.abcdef0123456789abcdef0123456789',
            ),
          );
          await pumpFrames(tester, total: const Duration(seconds: 3));
          expect(find.text('Registro en el club'), findsWidgets);
          expect(find.textContaining('v1.club1'), findsNothing);
        }, timeout: const Duration(seconds: 30));
        ciLog('functional-flow: deep link OK — done');
      } catch (e) {
        await saveCiFailureScreenshot(binding, 'functional-flow-failure');
        rethrow;
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}