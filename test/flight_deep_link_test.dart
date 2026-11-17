import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/flight_deep_link.dart';

void main() {
  test('parses check-in app link', () {
    const url = 'https://flight.heavenly.cl/c/demo-club/q/v1.demo.9.sig';
    final link = FlightDeepLink.parseUri(Uri.parse(url));
    expect(link, isA<CheckinDeepLink>());
    final checkin = link! as CheckinDeepLink;
    expect(checkin.clubSlug, 'demo-club');
    expect(checkin.token, 'v1.demo.9.sig');
  });

  test('parses magic link', () {
    final link = FlightDeepLink.parseUri(Uri.parse('https://flight.heavenly.cl/auth/magic/abc123'));
    expect(link, isA<MagicLinkDeepLink>());
    expect((link! as MagicLinkDeepLink).token, 'abc123');
  });

  test('parseCheckinScan accepts URL or raw token', () {
    final fromUrl = FlightDeepLink.parseCheckinScan(
      'https://flight.heavenly.cl/c/aeroclub/q/v1.a.1.ff',
    );
    expect(fromUrl?.clubSlug, 'aeroclub');
    expect(fromUrl?.token, 'v1.a.1.ff');

    final raw = FlightDeepLink.parseCheckinScan('v1.only.token.here');
    expect(raw?.clubSlug, isNull);
    expect(raw?.token, 'v1.only.token.here');
  });
}