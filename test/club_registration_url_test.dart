import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/club_registration_url.dart';

void main() {
  test('defaults club slug to cas', () {
    expect(ClubRegistrationUrl.resolveClubSlug(), 'cas');
  });

  test('prefers active then client slug', () {
    expect(
      ClubRegistrationUrl.resolveClubSlug(activeClubSlug: 'demo', clientClubSlug: 'other'),
      'demo',
    );
    expect(
      ClubRegistrationUrl.resolveClubSlug(clientClubSlug: 'other'),
      'other',
    );
  });

  test('legacy registration URL uses club-register.html', () {
    final uri = ClubRegistrationUrl.build(
      serverBaseUrl: 'https://flight.heavenly.cl/',
      clubSlug: 'cas',
    );
    expect(uri.toString(), 'https://flight.heavenly.cl/club-register.html?club=cas');
  });
}