import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/ci_test_keys.dart';

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

Future<void> waitForAbsent(
  WidgetTester tester,
  Finder finder, {
  String? label,
  Duration timeout = const Duration(seconds: 30),
  Duration pumpStep = const Duration(milliseconds: 200),
}) async {
  final name = label ?? finder.toString();
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(pumpStep);
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Timed out after ${timeout.inSeconds}s waiting for absence of: $name');
}

/// Hub stays mounted under a pushed check-in route; wait until it is on top.
Future<void> waitForHubExposed(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  await waitForAbsent(
    tester,
    find.byKey(FlightVisTestKeys.checkinScreen),
    label: 'check-in route dismissed',
    timeout: timeout,
  );
  await waitForTappable(
    tester,
    find.byKey(FlightVisTestKeys.hubCheckIn),
    label: 'hub check-in card (route on top)',
    timeout: timeout,
  );
}

Future<void> waitForTappable(
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
    if (finder.evaluate().isEmpty) continue;
    final hit = await _finderHitTestable(tester, finder);
    if (hit) return;
  }
  throw TestFailure('Timed out after ${timeout.inSeconds}s waiting for tappable: $name');
}

Future<bool> _finderHitTestable(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(finder);
    final center = tester.getCenter(finder.first);
    tester.hitTestOnBinding(center);
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> leaveCheckinForHub(WidgetTester tester) async {
  await tapWhenFound(
    tester,
    find.byKey(FlightVisTestKeys.checkinContinue),
    label: 'check-in continue',
    timeout: const Duration(seconds: 30),
  );
  await pumpFrames(tester, total: const Duration(milliseconds: 500));
  await waitForHubExposed(tester, timeout: const Duration(seconds: 45));
}

Future<void> waitForAnyFound(
  WidgetTester tester,
  List<Finder> finders, {
  required String label,
  Duration timeout = const Duration(seconds: 90),
  Duration pumpStep = const Duration(milliseconds: 200),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(pumpStep);
    for (final finder in finders) {
      if (finder.evaluate().isNotEmpty) return;
    }
  }
  throw TestFailure('Timed out after ${timeout.inSeconds}s waiting for any of: $label');
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

Future<void> ciStep(
  WidgetTester tester,
  String step,
  Future<void> Function() body, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  ciLog('step: $step (timeout ${timeout.inSeconds}s)');
  try {
    await body().timeout(timeout, onTimeout: () {
      throw TestFailure('Step timed out after ${timeout.inSeconds}s: $step');
    });
  } catch (e, st) {
    ciLog('step failed: $step — $e');
    Error.throwWithStackTrace(TestFailure('CI step failed: $step — $e'), st);
  }
}

/// Hub, login guest entry, or permissions (fresh install without screenshot flags).
Future<void> waitForPilotShellReady(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  await waitForAnyFound(
    tester,
    [
      find.byKey(FlightVisTestKeys.hub),
      find.byKey(FlightVisTestKeys.permissionsScreen),
      find.byKey(FlightVisTestKeys.loginGuest),
    ],
    label: 'pilot shell (hub, permissions, or login)',
    timeout: timeout,
  );
}

Future<void> advancePermissionsOnboardingIfNeeded(WidgetTester tester) async {
  const maxRounds = 12;
  for (var round = 0; round < maxRounds; round++) {
    final onPermissions = find.byKey(FlightVisTestKeys.permissionsScreen);
    await tester.pump(const Duration(milliseconds: 200));
    if (onPermissions.evaluate().isEmpty) break;

    final primary = find.byKey(FlightVisTestKeys.permissionsPrimary);
    if (primary.evaluate().isNotEmpty) {
      ciLog('permissions tap primary ($round)');
      await tester.tap(primary);
      await pumpFrames(tester, total: const Duration(seconds: 1));
      continue;
    }

    const labels = [
      'Continuar',
      'Conceder ubicación',
      'Continuar a segundo plano',
      'Conceder notificaciones',
      'Abrir ajustes de batería',
      'Listo para volar',
    ];
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

Future<void> ensureOnPilotHub(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  await waitForPilotShellReady(tester, timeout: timeout);
  await advancePermissionsOnboardingIfNeeded(tester);

  if (find.byKey(FlightVisTestKeys.loginGuest).evaluate().isNotEmpty) {
    await tapWhenFound(
      tester,
      find.byKey(FlightVisTestKeys.loginGuest),
      label: 'login continue as guest',
      timeout: timeout,
    );
  }

  await waitForFound(
    tester,
    find.byKey(FlightVisTestKeys.hub),
    label: 'pilot hub',
    timeout: timeout,
  );
}

bool _emulatorSurfaceConverted = false;

Future<void> ensureEmulatorScreenshotSurface(
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  if (_emulatorSurfaceConverted) return;
  ciLog('screenshot: convertFlutterSurfaceToImage (once)');
  await binding.convertFlutterSurfaceToImage().timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      throw TestFailure('convertFlutterSurfaceToImage timed out after 45s');
    },
  );
  _emulatorSurfaceConverted = true;
}

Future<void> saveEmulatorScreenshot(IntegrationTestWidgetsFlutterBinding binding, String name) async {
  if (!AppConfig.captureScreenshots) return;
  await ensureEmulatorScreenshotSurface(binding);
  final bytes = await binding.takeScreenshot(name).timeout(
    const Duration(seconds: 20),
    onTimeout: () {
      throw TestFailure('takeScreenshot($name) timed out after 20s');
    },
  );
  if (bytes.isEmpty) return;
  // ignore: avoid_slow_async_io
  final dir = Directory('/sdcard/Download/flightvis-emulator');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  // ignore: avoid_slow_async_io
  File('${dir.path}/$name.png').writeAsBytesSync(bytes);
  ciLog('screenshot: saved $name (${bytes.length} bytes)');
}

/// Failure screenshot for functional CI (capture flag off).
Future<void> saveCiFailureScreenshot(IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
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
  } catch (e) {
    ciLog('failure screenshot skipped: $e');
  }
}