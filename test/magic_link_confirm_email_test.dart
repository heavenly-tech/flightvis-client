import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/api/flight_vis_client.dart';
import 'package:flight_vis/storage/preferences_store.dart';
import 'package:flight_vis/util/flight_deep_link.dart';

void main() {
  test('M-33 prefers stored magic-link request email over link query email', () {
    final pendingEmail = 'pilot@club.test';
    final link = AccountMagicLinkDeepLink(
      token: 'tok',
      email: 'attacker@evil.test',
    );

    String? resolveTitleEmail({
      required PendingMagicLinkRequest? pending,
      required AccountProfile? account,
      required PilotProfile? pilot,
      required AccountMagicLinkDeepLink link,
    }) {
      final pendingEmail = pending?.email.trim();
      if (pendingEmail != null && pendingEmail.isNotEmpty) return pendingEmail;
      final accountEmail = account?.email.trim();
      if (accountEmail != null && accountEmail.isNotEmpty) return accountEmail;
      final pilotEmail = pilot?.email.trim();
      if (pilotEmail != null && pilotEmail.isNotEmpty) return pilotEmail;
      return null;
    }

    expect(
      resolveTitleEmail(
        pending: PendingMagicLinkRequest(
          nonce: 'n',
          email: pendingEmail,
          expiresAtMs: 2,
        ),
        account: null,
        pilot: null,
        link: link,
      ),
      pendingEmail,
    );
    expect(
      resolveTitleEmail(
        pending: null,
        account: AccountProfile(
          id: 'a1',
          email: 'acct@heavenly.cl',
          emailVerified: true,
        ),
        pilot: null,
        link: link,
      ),
      'acct@heavenly.cl',
    );
    expect(
      resolveTitleEmail(
        pending: null,
        account: null,
        pilot: PilotProfile(
          id: 'p1',
          name: 'Pablo',
          email: 'pilot@heavenly.cl',
          status: 'approved',
          role: 'pilot',
        ),
        link: link,
      ),
      'pilot@heavenly.cl',
    );
    expect(
      resolveTitleEmail(
        pending: null,
        account: null,
        pilot: null,
        link: link,
      ),
      isNull,
    );
  });
}