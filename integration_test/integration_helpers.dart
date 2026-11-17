import 'package:flutter_test/flutter_test.dart';

/// Taps through [PermissionsOnboardingScreen] when first run shows it (Spanish copy).
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
      if (find.text(label).evaluate().isNotEmpty) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle(const Duration(seconds: 2));
        tapped = true;
        break;
      }
    }
    if (!tapped) break;
  }
}