import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/main.dart' as app;

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

  testWidgets('guest-first flow with login options (ES)', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '01-guest-hub');

    await tester.tap(find.text('Iniciar sesión'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await saveScreenshot(binding, '02-login-options');

    await tester.tap(find.text('Continuar sin iniciar sesión'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await saveScreenshot(binding, '03-hub-after-permissions');

    await tester.tap(find.text('Check-in club'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.enterText(
      find.widgetWithText(TextField, 'O pegue el token de check-in'),
      _checkinUrl,
    );
    await tester.tap(find.text('Enviar token'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '04-checkin-success');

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('Detalles del vuelo'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '05-flight-details');

    await tester.tap(find.text('Comenzar tracking'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '06-broadcasting');

    expect(find.text('Finalizar tracking'), findsOneWidget);
  });
}