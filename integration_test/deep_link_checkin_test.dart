import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/main.dart' as app;
import 'package:flight_vis/services/deep_link_dispatcher.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

import 'integration_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'app link opens check-in with slug and token',
    (tester) async {
      ciLog('deeplink: start');
      expect(AppConfig.screenshotTest, isTrue);
      app.main();
      await pumpFrames(tester, total: const Duration(seconds: 4));

      await advancePermissionsOnboardingIfNeeded(tester);
      await waitForFound(tester, find.text('Check-in club'), label: 'hub ready');

      await DeepLinkTestHooks.dispatch(
        const CheckinDeepLink(
          clubSlug: 'demo-club',
          token: 'v1.club1.999999.abcdef0123456789abcdef0123456789',
        ),
      );
      await pumpFrames(tester, total: const Duration(seconds: 3));

      expect(find.text('Check-in club'), findsWidgets);
      expect(find.textContaining('v1.club1'), findsNothing);
      ciLog('deeplink: done');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}