import 'dart:io';

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

Future<void> openAccessRequestForm(WidgetTester tester) async {
  await tester.tap(find.text('Request another aircraft'));
  await tester.pumpAndSettle();
}

Future<void> submitAccessRequest(WidgetTester tester, String tail) async {
  await openAccessRequestForm(tester);
  await tester.enterText(find.widgetWithText(TextField, 'Tail (CC-XXX)'), tail);
  await tester.tap(find.text('Submit access request'));
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canonical pre-flight flow screenshots', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '01-login');

    await tester.enterText(find.byType(TextField).at(0), 'pilot@demo.test');
    await tester.enterText(find.byType(TextField).at(1), 'password12');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste device token'),
      _deviceToken,
    );
    await tester.tap(find.text('Save token'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await saveScreenshot(binding, '02-hub');

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

    await tester.tap(find.text('Flight details'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    await saveScreenshot(binding, '04-flight-details');

    await openAccessRequestForm(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Tail (CC-XXX)'), 'CC-PEND');
    await saveScreenshot(binding, '07-access-request');
    await tester.tap(find.text('Submit access request'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await saveScreenshot(binding, '08-access-pending');

    await submitAccessRequest(tester, 'CC-BAD');
    await tester.pumpAndSettle(const Duration(seconds: 4));
    await saveScreenshot(binding, '09-access-rejected');

    await submitAccessRequest(tester, 'CC-OK');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 3));
      if (find.textContaining('CC-OK').evaluate().isNotEmpty &&
          find.text('Start is disabled until admin approves access for this tail.').evaluate().isEmpty) {
        break;
      }
    }
    await saveScreenshot(binding, '10-access-approved');

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle(const Duration(seconds: 4));

    await saveScreenshot(binding, '05-broadcasting');
    expect(find.text('Stop'), findsOneWidget);
    await saveScreenshot(binding, '06-stop');
  }, timeout: const Timeout(Duration(minutes: 8)));
}