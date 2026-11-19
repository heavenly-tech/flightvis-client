import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flight_vis/util/account_signup_availability.dart';

void main() {
  test('isAvailable is true on 2xx GET', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/signup');
      if (request.method == 'HEAD') {
        return http.Response('', 404);
      }
      return http.Response('<html></html>', 200);
    });
    expect(
      await AccountSignupAvailability.isAvailable(
        'https://flight.heavenly.cl',
        client: client,
      ),
      isTrue,
    );
  });

  test('isAvailable is false on 404 GET', () async {
    final client = MockClient((request) async {
      return http.Response('not found', 404);
    });
    expect(
      await AccountSignupAvailability.isAvailable(
        'https://flight.heavenly.cl',
        client: client,
      ),
      isFalse,
    );
  });
}