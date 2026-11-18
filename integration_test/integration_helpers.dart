import 'dart:io';

import 'package:flutter/material.dart';
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

Future<void> waitForTappable(
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
    if (finder.evaluate().isEmpty) continue;
    try {
      await tester.ensureVisible(finder);
      await tester.tap(finder, warnIfMissed: true);
      await tester.pump(const Duration(milliseconds: 100));
      return;
    } catch (_) {
      // keep pumping until timeout
    }
  }
  throw TestFailure('Timed out after ${timeout.inSeconds}s waiting for tappable: $name');
}

Future<void> _popCheckinRouteIfVisible(WidgetTester tester) async {
  final checkin = find.byKey(FlightVisTestKeys.checkinScreen);
  if (checkin.evaluate().isEmpty) return;

  final navigator = tester
      .element(checkin.first)
      .findAncestorStateOfType<NavigatorState>();
  if (navigator != null && navigator.canPop()) {
    ciLog('hub: ancestor navigator.pop (check-in still visible)');
    navigator.pop();
    await pumpFrames(tester, total: const Duration(seconds: 2));
  }
}

/// Emulator integration taps can miss [FilledButton] hits; invoke [onPressed] when unambiguous.
Future<void> activateCheckinContinue(WidgetTester tester) async {
  final continueFinder = find.byKey(FlightVisTestKeys.checkinContinue);
  await waitForFound(
    tester,
    continueFinder,
    label: 'check-in continue',
    timeout: const Duration(seconds: 25),
  );
  final matches = continueFinder.evaluate();
  if (matches.length == 1) {
    final button = tester.widget<FilledButton>(continueFinder);
    if (button.onPressed != null) {
      ciLog('hub: invoke check-in continue onPressed');
      button.onPressed!();
      await pumpFrames(tester, total: const Duration(seconds: 2));
      return;
    }
  }
  await tester.ensureVisible(continueFinder);
  await tester.tap(continueFinder);
  await pumpFrames(tester, total: const Duration(seconds: 2));
}

Future<void> openHubFlightDetails(WidgetTester tester) async {
  final finder = find.byKey(FlightVisTestKeys.hubFlightDetails);
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isEmpty) continue;
    final tile = tester.widget<ListTile>(finder);
    if (tile.enabled && tile.onTap != null) {
      ciLog('hub: invoke flight details onTap');
      tile.onTap!();
      await pumpFrames(tester, total: const Duration(seconds: 2));
      return;
    }
  }
  throw TestFailure('Timed out waiting for enabled hub flight details');
}

Future<void> leaveCheckinForHub(WidgetTester tester) async {
  final checkinRoute = find.byKey(FlightVisTestKeys.checkinScreen);
  await activateCheckinContinue(tester);
  try {
    await waitForAbsent(
      tester,
      checkinRoute,
      label: 'check-in route',
      timeout: const Duration(seconds: 20),
    );
  } on TestFailure {
    await _popCheckinRouteIfVisible(tester);
    await waitForAbsent(
      tester,
      checkinRoute,
      label: 'check-in route after pop',
      timeout: const Duration(seconds: 20),
    );
  }

  await waitForFound(
    tester,
    find.byKey(FlightVisTestKeys.hub),
    label: 'pilot hub',
    timeout: const Duration(seconds: 20),
  );
  ciLog('hub: ready after check-in continue');
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
  await tester.ensureVisible(finder);
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