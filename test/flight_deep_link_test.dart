import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/flight_deep_link.dart';

void main() {
  group('https app links', () {
    test('parses check-in path', () {
      const url = 'https://flight.heavenly.cl/c/demo-club/q/v1.demo.9.sig';
      final link = FlightDeepLink.parseIncoming(Uri.parse(url));
      expect(link, isA<CheckinDeepLink>());
      final checkin = link! as CheckinDeepLink;
      expect(checkin.clubSlug, 'demo-club');
      expect(checkin.token, 'v1.demo.9.sig');
    });

    test('parses legacy magic path', () {
      final link = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/auth/magic/abc123'),
      );
      expect(link, isA<MagicLinkDeepLink>());
      expect((link! as MagicLinkDeepLink).token, 'abc123');
    });

    test('parses server magic consume URL (C-5)', () {
      final link = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/api/club/auth/magic?token=abc123'),
      );
      expect(link, isA<MagicLinkDeepLink>());
      expect((link! as MagicLinkDeepLink).token, 'abc123');
    });

    test('ignores unrelated paths on production host', () {
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://flight.heavenly.cl/club/screen')),
        isNull,
      );
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://flight.heavenly.cl/')),
        isNull,
      );
    });

    test('ignores other hosts', () {
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://evil.example/c/x/q/t')),
        isNull,
      );
    });
  });

  group('malformed check-in paths', () {
    test('rejects missing token segment', () {
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://flight.heavenly.cl/c/slug/q')),
        isNull,
      );
    });

    test('rejects empty slug', () {
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://flight.heavenly.cl/c//q/tok')),
        isNull,
      );
    });

    test('rejects wrong segment layout', () {
      expect(
        FlightDeepLink.parseIncoming(Uri.parse('https://flight.heavenly.cl/c/slug/t/tok')),
        isNull,
      );
    });
  });

  group('intent:// fallback', () {
    test('maps intent URL to https check-in', () {
      final uri = Uri.parse(
        'intent://flight.heavenly.cl/c/demo-club/q/v1.tok#Intent;'
        'scheme=https;package=cl.heavenly.flightvis;end',
      );
      final link = FlightDeepLink.parseIncoming(uri);
      expect(link, isA<CheckinDeepLink>());
      final checkin = link! as CheckinDeepLink;
      expect(checkin.clubSlug, 'demo-club');
      expect(checkin.token, 'v1.tok');
    });

    test('rejects intent for other package', () {
      final uri = Uri.parse(
        'intent://flight.heavenly.cl/c/a/q/t#Intent;scheme=https;package=com.other.app;end',
      );
      expect(FlightDeepLink.parseIncoming(uri), isNull);
    });

    test('rejects non-https intent scheme', () {
      final uri = Uri.parse(
        'intent://flight.heavenly.cl/c/a/q/t#Intent;scheme=custom;package=cl.heavenly.flightvis;end',
      );
      expect(FlightDeepLink.parseIncoming(uri), isNull);
    });
  });

  test('ignores untrusted extras without deep link path (C-4)', () {
    expect(
      FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/'),
        extras: {'slug': 'my-club', 'token': 'v1.x'},
      ),
      isNull,
    );
  });

  test('parseCheckinScan accepts URL, intent string, or raw token', () {
    final fromUrl = FlightDeepLink.parseCheckinScan(
      'https://flight.heavenly.cl/c/aeroclub/q/v1.a.1.ff',
    );
    expect(fromUrl?.clubSlug, 'aeroclub');

    final raw = FlightDeepLink.parseCheckinScan('v1.only.token.here');
    expect(raw?.clubSlug, isNull);
    expect(raw?.token, 'v1.only.token.here');
  });
}