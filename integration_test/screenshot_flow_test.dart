import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/ci_test_keys.dart';
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
      await pumpFrames(tester, total: const Duration(seconds: 3));
      if (AppConfig.captureScreenshots) {
        await ensureEmulatorScreenshotSurface(binding);
      }

      try {
        await ciStep(tester, 'reach hub', () async {
          await ensureOnPilotHub(tester, timeout: const Duration(seconds: 90));
        }, timeout: const Duration(seconds: 95));
        await saveEmulatorScreenshot(binding, '01-guest-hub');

        await ciStep(tester, 'open login', () async {
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.hubSignIn),
            label: 'hub sign in',
            timeout: const Duration(seconds: 30),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.loginGuest),
            label: 'login screen',
            timeout: const Duration(seconds: 30),
          );
        }, timeout: const Duration(seconds: 60));
        await saveEmulatorScreenshot(binding, '02-login-options');

        await ciStep(tester, 'continue as guest', () async {
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.loginGuest),
            label: 'continue as guest',
            timeout: const Duration(seconds: 30),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.hub),
            label: 'hub after guest',
            timeout: const Duration(seconds: 30),
          );
        }, timeout: const Duration(seconds: 60));
        await saveEmulatorScreenshot(binding, '03-hub-after-permissions');

        await ciStep(tester, 'open check-in', () async {
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.hubCheckIn),
            label: 'hub check-in',
            timeout: const Duration(seconds: 30),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinScreen),
            label: 'check-in screen',
            timeout: const Duration(seconds: 30),
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinManualEntry),
            label: 'check-in manual entry',
            timeout: const Duration(seconds: 30),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.checkinPasteField),
            label: 'check-in paste field',
            timeout: const Duration(seconds: 30),
          );
        }, timeout: const Duration(seconds: 60));

        await ciStep(tester, 'submit check-in', () async {
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
            label: 'check-in success',
            timeout: const Duration(seconds: 45),
          );
        }, timeout: const Duration(seconds: 90));
        await saveEmulatorScreenshot(binding, '04-checkin-success');

        await ciStep(tester, 'flight details + tracking', () async {
          await activateCheckinContinue(tester);
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.tailPicker),
            label: 'tail picker',
            timeout: const Duration(seconds: 90),
          );
          await waitForAbsent(
            tester,
            find.byType(CircularProgressIndicator),
            label: 'tail list loading',
            timeout: const Duration(seconds: 45),
          );
          await pumpFrames(tester, total: const Duration(milliseconds: 500));
          await saveEmulatorScreenshot(binding, '05-flight-details');

          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.tailStart),
            label: 'start tracking button',
            timeout: const Duration(seconds: 45),
          );
          await tapWhenFound(
            tester,
            find.byKey(FlightVisTestKeys.tailStart),
            label: 'start tracking',
            timeout: const Duration(seconds: 30),
          );
          await waitForFound(
            tester,
            find.byKey(FlightVisTestKeys.trackingStop),
            label: 'tracking stop',
            timeout: const Duration(seconds: 45),
          );
        }, timeout: const Duration(seconds: 180));
        await saveEmulatorScreenshot(binding, '06-broadcasting');

        await pumpFrames(tester, total: const Duration(seconds: 1));
        expect(find.byKey(FlightVisTestKeys.trackingStop), findsOneWidget);

        await ciStep(tester, 'stop tracking (teardown)', () async {
          await stopTrackingAndReturnToHub(tester);
        }, timeout: const Duration(seconds: 120));
        ciLog('screenshots: done');
      } catch (e) {
        await saveCiFailureScreenshot(binding, 'screenshot-flow-failure');
        rethrow;
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}