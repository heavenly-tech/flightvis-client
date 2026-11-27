import '../models/local_flight.dart';
import 'local_flight_store.dart';
import 'preferences_store.dart';

/// Enforces M-28 legacy-flight isolation and persisted guest-flight adoption
/// rules consistently across startup/sign-in prompts and `LocalFlightsListScreen`.
///
/// State machine for migrated pre-#11 legacy files (`local_flights/legacy/`):
/// - **Guest** (`bucket == 'guest'` or reserved): never claims, never sees,
///   never adopts, never deletes legacy files.
/// - **Unclaimed & unresolved** (`resolved == false`, `claimant == null`): the
///   FIRST approved signed-in account claims the legacy files by persisting its
///   hashed bucket ID in [PreferencesStore.legacyFlightsClaimantBucketKey],
///   then sees the one-time adopt-or-delete choice.
/// - **Dismissed without deciding** (`resolved == false`, `claimant == acct_A`):
///   legacy files remain in `legacy/` claimed exclusively by `acct_A`. Only
///   `acct_A` is offered the choice again; any other account (`acct_B`) and
///   guests see nothing.
/// - **Resolved** (`resolved == true`): the claimant adopted or deleted the
///   legacy files. Neither the claimant, any other account, nor guests are ever
///   offered legacy files again.
abstract final class LocalFlightMigration {
  static bool _isSignedInAccountBucket(String bucket) {
    if (LocalFlightStore.isReservedBucket(bucket)) return false;
    return LocalFlightStore.sanitizeBucket(bucket) !=
        LocalFlightStore.guestBucket;
  }

  /// Checks whether [accountBucket] is eligible to see migrated legacy flights,
  /// claiming them exclusively for [accountBucket] if no account has claimed
  /// them yet.
  ///
  /// Returns the count of legacy flights to offer, or `0` if [accountBucket] is
  /// guest/reserved, legacy flights were already resolved, none exist, or
  /// another account already claimed them.
  static Future<int> claimOrCheckLegacyFlights({
    required LocalFlightStore store,
    required PreferencesStore prefs,
    required String accountBucket,
  }) async {
    if (!_isSignedInAccountBucket(accountBucket)) return 0;
    if (prefs.legacyFlightsResolved()) return 0;
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);

    final count = await store.countLegacyFlights();
    if (count <= 0) return 0;

    final claimant = prefs.legacyFlightsClaimantBucket();
    if (claimant == null) {
      await prefs.setLegacyFlightsClaimantBucket(sanitized);
      return count;
    }
    if (claimant != sanitized) return 0;
    return count;
  }

  /// Moves all claimed legacy flights into [accountBucket] and persists the
  /// one-time resolved marker so no other account (or guest) is ever offered
  /// them again.
  ///
  /// Refuses (returns `0`) if [accountBucket] is guest/reserved, legacy flights
  /// are already resolved, or another account holds the claim.
  static Future<int> adoptClaimedLegacyFlights({
    required LocalFlightStore store,
    required PreferencesStore prefs,
    required String accountBucket,
  }) async {
    if (!_isSignedInAccountBucket(accountBucket)) return 0;
    if (prefs.legacyFlightsResolved()) return 0;
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);

    final claimant = prefs.legacyFlightsClaimantBucket();
    if (claimant != null && claimant != sanitized) return 0;
    if (claimant == null) {
      await prefs.setLegacyFlightsClaimantBucket(sanitized);
    }

    final moved = await store.adoptLegacyFlights(toBucket: sanitized);
    await prefs.setLegacyFlightsResolved(true);
    return moved;
  }

  /// Permanently deletes all claimed legacy flights and persists the one-time
  /// resolved marker so nobody is ever offered them again.
  ///
  /// Refuses (returns `0`) if [accountBucket] is guest/reserved, legacy flights
  /// are already resolved, or another account holds the claim.
  static Future<int> deleteClaimedLegacyFlights({
    required LocalFlightStore store,
    required PreferencesStore prefs,
    required String accountBucket,
  }) async {
    if (!_isSignedInAccountBucket(accountBucket)) return 0;
    if (prefs.legacyFlightsResolved()) return 0;
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);

    final claimant = prefs.legacyFlightsClaimantBucket();
    if (claimant != null && claimant != sanitized) return 0;
    if (claimant == null) {
      await prefs.setLegacyFlightsClaimantBucket(sanitized);
    }

    final deleted = await store.deleteLegacyFlights();
    await prefs.setLegacyFlightsResolved(true);
    return deleted;
  }

  /// Returns guest-bucket flights that [accountBucket] has not explicitly
  /// chosen to leave on this phone ("Dejarlos en este teléfono").
  ///
  /// Returns an empty list for guests/reserved buckets and NEVER includes
  /// legacy flights.
  static Future<List<LocalFlight>> unacknowledgedGuestFlights({
    required LocalFlightStore store,
    required PreferencesStore prefs,
    required String accountBucket,
  }) async {
    if (!_isSignedInAccountBucket(accountBucket)) return const [];
    final sanitized = LocalFlightStore.sanitizeBucket(accountBucket);
    final guestFlights = await store.listFlights(
      bucket: LocalFlightStore.guestBucket,
    );
    if (guestFlights.isEmpty) return const [];
    final keptIds = prefs.keptOnPhoneGuestFlightIds(sanitized);
    if (keptIds.isEmpty) return guestFlights;
    return guestFlights.where((f) => !keptIds.contains(f.id)).toList();
  }
}
