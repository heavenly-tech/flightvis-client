import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/account_signup_url.dart';

void main() {
  test('signup URL is server-relative /signup', () {
    expect(
      AccountSignupUrl.build(serverBaseUrl: 'https://flight.heavenly.cl/').toString(),
      'https://flight.heavenly.cl/signup',
    );
    expect(
      AccountSignupUrl.build(serverBaseUrl: 'http://10.0.2.2:18080').toString(),
      'http://10.0.2.2:18080/signup',
    );
  });
}