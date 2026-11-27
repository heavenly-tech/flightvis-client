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

    test('parses app.html as home', () {
      final link = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/app.html'),
      );
      expect(link, isA<AppHomeDeepLink>());
    });

    test('parses server magic consume URL (C-5)', () {
      final link = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/api/club/auth/magic?token=abc123'),
      );
      expect(link, isA<MagicLinkDeepLink>());
      expect((link! as MagicLinkDeepLink).token, 'abc123');
    });

    test('parses account magic App Link URL with optional purpose (app F)', () {
      final withoutPurpose = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=acct_tok_1',
        ),
      );
      expect(
        withoutPurpose,
        const AccountMagicLinkDeepLink(token: 'acct_tok_1'),
      );

      final withPurpose = FlightDeepLink.parseIncoming(
        Uri.parse(
          'https://flight.heavenly.cl/api/account/auth/magic?token=acct_tok_2&purpose=account_signup',
        ),
      );
      expect(
        withPurpose,
        const AccountMagicLinkDeepLink(
          token: 'acct_tok_2',
          purpose: 'account_signup',
        ),
      );

      final intentFallback = FlightDeepLink.parseIncoming(
        Uri.parse(
          'intent://flight.heavenly.cl/api/account/auth/magic?token=acct_tok_3#Intent;'
          'scheme=https;package=cl.heavenly.flightvis;end',
        ),
      );
      expect(
        intentFallback,
        const AccountMagicLinkDeepLink(token: 'acct_tok_3'),
      );

      expect(
        FlightDeepLink.parseIncoming(
          Uri.parse('https://flight.heavenly.cl/api/account/auth/magic'),
        ),
        isNull,
      );
      expect(
        FlightDeepLink.parseIncoming(
          Uri.parse('https://evil.example/api/account/auth/magic?token=x'),
        ),
        isNull,
      );
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
    expect(raw?.isClaimToken, isFalse);
  });

  group('PR #36 handoff/claim tokens (h1.…)', () {
    test('parses https App Link carrying h1 claim token', () {
      const claim = 'h1.club_1.abcdef0123456789abcdef0123456789';
      const url = 'https://flight.heavenly.cl/c/demo-club/q/$claim';
      final link = FlightDeepLink.parseIncoming(Uri.parse(url));
      expect(link, isA<CheckinDeepLink>());
      final checkin = link! as CheckinDeepLink;
      expect(checkin.clubSlug, 'demo-club');
      expect(checkin.token, claim);
      expect(checkin.isClaimToken, isTrue);
    });

    test('parses intent:// fallback carrying h1 claim token', () {
      const claim = 'h1.club_1.99887766554433221100';
      final uri = Uri.parse(
        'intent://flight.heavenly.cl/c/demo-club/q/$claim#Intent;'
        'scheme=https;package=cl.heavenly.flightvis;end',
      );
      final link = FlightDeepLink.parseIncoming(uri);
      expect(link, isA<CheckinDeepLink>());
      final checkin = link! as CheckinDeepLink;
      expect(checkin.clubSlug, 'demo-club');
      expect(checkin.token, claim);
      expect(checkin.isClaimToken, isTrue);
    });

    test('parses club URL with claim query parameter', () {
      const claim = 'h1.club_1.querytoken123456';
      final link = FlightDeepLink.parseIncoming(
        Uri.parse('https://flight.heavenly.cl/c/demo-club?claim=$claim'),
      );
      expect(link, const CheckinDeepLink(clubSlug: 'demo-club', token: claim));
      expect((link! as CheckinDeepLink).isClaimToken, isTrue);
    });

    test('parseCheckinScan preserves h1 claim token from URL or raw paste', () {
      const claim = 'h1.club_1.rawclaimtoken9876';
      final fromUrl = FlightDeepLink.parseCheckinScan(
        'https://flight.heavenly.cl/c/aeroclub/q/$claim',
      );
      expect(fromUrl?.clubSlug, 'aeroclub');
      expect(fromUrl?.token, claim);
      expect(fromUrl?.isClaimToken, isTrue);

      final raw = FlightDeepLink.parseCheckinScan(claim);
      expect(raw?.clubSlug, isNull);
      expect(raw?.token, claim);
      expect(raw?.isClaimToken, isTrue);
    });
  });
}