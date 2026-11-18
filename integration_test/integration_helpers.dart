import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';

/// CI progress markers (visible in `flutter test` / logcat).
void ciLog(String step) {
  debugPrint('flightvis-ci: $step');
  // ignore: avoid_print
  print('flightvis-ci: $step');
}

/// Bounded frame pumps (avoids [WidgetTester.pumpAndSettle] on live timers/animations).
Future<void> pumpFrames(
  WidgetTester tester, {
  Duration total = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
  }
}

Future<void> waitForFound(
  WidgetTester tester,
  Finder finder, {
  String? label,
  Duration timeout = const Duration(seconds: 45),
  Duration pumpStep = const Duration(milliseconds: 200),
}) async {
  final name = label ?? finder.toString();
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(pumpStep);
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out after ${timeout.inSeconds}s waiting for: $name');
}

Future<void> tapWhenFound(
  WidgetTester tester,
  Finder finder, {
  String? label,
  Duration timeout = const Duration(seconds: 45),
}) async {
  await waitForFound(tester, finder, label: label, timeout: timeout);
  await tester.tap(finder);
  await pumpFrames(tester);
}

Future<void> saveEmulatorScreenshot(IntegrationTestWidgetsFlutterBinding binding, String name) async {
  if (!AppConfig.captureScreenshots) return;
  await binding.convertFlutterSurfaceToImage();
  final bytes = await binding.takeScreenshot(name);
  if (bytes.isEmpty) return;
  // ignore: avoid_slow_async_io
  final dir = Directory('/sdcard/Download/flightvis-emulator');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  // ignore: avoid_slow_async_io
  File('${dir.path}/$name.png').writeAsBytesSync(bytes);
}

/// Skips permissions UI when screenshot build flags are active.
Future<void> advancePermissionsOnboardingIfNeeded(WidgetTester tester) async {
  const labels = [
    'Continuar',
    'Conceder ubicación',
    'Continuar a segundo plano',
    'Conceder notificaciones',
    'Abrir ajustes de batería',
    'Listo para volar',
  ];
  for (var round = 0; round < 8; round++) {
    var tapped = false;
    for (final label in labels) {
      final finder = find.text(label);
      if (finder.evaluate().isNotEmpty) {
        ciLog('permissions tap "$label"');
        await tester.tap(finder);
        await pumpFrames(tester, total: const Duration(seconds: 1));
        tapped = true;
        break;
      }
    }
    if (!tapped) break;
  }
}