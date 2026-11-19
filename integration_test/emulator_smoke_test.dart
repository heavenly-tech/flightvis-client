import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:flight_vis/app_config.dart';

import 'integration_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mock API reachable from emulator (10.0.2.2)',
    (_) async {
      ciLog('smoke: compile flags baseUrl=${AppConfig.defaultBaseUrl} screenshot=${AppConfig.screenshotTest}');
      expect(
        AppConfig.defaultBaseUrl,
        'http://10.0.2.2:18080',
        reason: 'FLIGHTVIS_BASE_URL must be compiled into the integration APK',
      );
      expect(AppConfig.screenshotTest, isTrue);

      final uri = Uri.parse('${AppConfig.defaultBaseUrl}/api/ci-health');
      ciLog('smoke: GET $uri');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      expect(response.statusCode, 200, reason: response.body);
      expect(response.body, contains('"ok"'));
      ciLog('smoke: mock API OK');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}