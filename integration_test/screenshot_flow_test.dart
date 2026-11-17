import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/main.dart' as app;

const _deviceToken = 'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';
const _checkinToken = 'v1.club1.999999.abcdef0123456789abcdef0123456789';

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

  testWidgets('pilot flow screenshots', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '01-login');

    await tester.enterText(find.byType(TextField).at(0), 'pilot@demo.test');
    await tester.enterText(find.byType(TextField).at(1), 'password12');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '02-pairing');

    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste device token'),
      _deviceToken,
    );
    await tester.tap(find.text('Save token'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '04-permissions');

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('Club check-in'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste check-in token'),
      _checkinToken,
    );
    await tester.tap(find.text('Submit pasted token'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '03-checkin-success');

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('Start flight'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '05-tail-picker');

    await tester.tap(find.text('Start tracking'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '06-tracking-active');
  });
}