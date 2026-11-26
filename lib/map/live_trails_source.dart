import '../api/flight_vis_client.dart';
import '../storage/preferences_store.dart';

/// Strategy injecting how [TrackingMapCard] fetches remote aircraft trails.
///
/// Decouples guest (anonymous public-only), authenticated (club + public), and
/// static (saved local flight) modes without sprawling branching inside the map.
abstract class LiveTrailsSource {
  const LiveTrailsSource();

  /// Whether the Club layer chip is available and pollable.
  bool get supportsClubLayer;

  /// Whether `401` responses mean the user's session expired and should show
  /// the inline sign-in prompt.
  bool get supportsAuthExpiry;

  /// Whether remote polling is supported at all (false for static playback).
  bool get supportsRemotePolling => true;

  Future<LiveTrailsResponse> fetch({
    required bool includeClub,
    required bool includePublic,
    double? lat,
    double? lon,
    int? radiusKm,
    String? ifNoneMatch,
  });
}

/// Authenticated pilot source backed by `GET /api/me/live-trails`.
class AuthenticatedLiveTrailsSource extends LiveTrailsSource {
  const AuthenticatedLiveTrailsSource(this.client);

  final FlightVisClient client;

  @override
  bool get supportsClubLayer => true;

  @override
  bool get supportsAuthExpiry => true;

  @override
  Future<LiveTrailsResponse> fetch({
    required bool includeClub,
    required bool includePublic,
    double? lat,
    double? lon,
    int? radiusKm,
    String? ifNoneMatch,
  }) {
    return client.fetchLiveTrails(
      includeClub: includeClub,
      includePublic: includePublic,
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
      ifNoneMatch: ifNoneMatch,
    );
  }
}

/// Guest / anonymous public-only source backed by `GET /api/public/live-trails`.
///
/// Sends zero auth headers (`Cookie`/`Authorization`) and never polls Club.
class PublicOnlyLiveTrailsSource extends LiveTrailsSource {
  const PublicOnlyLiveTrailsSource(this.client);

  final FlightVisClient client;

  @override
  bool get supportsClubLayer => false;

  @override
  bool get supportsAuthExpiry => false;

  @override
  Future<LiveTrailsResponse> fetch({
    required bool includeClub,
    required bool includePublic,
    double? lat,
    double? lon,
    int? radiusKm,
    String? ifNoneMatch,
  }) async {
    if (!includePublic || lat == null || lon == null) {
      return const LiveTrailsResponse(flights: []);
    }
    return client.fetchPublicLiveTrails(
      lat: lat,
      lon: lon,
      radiusKm: radiusKm ?? PreferencesStore.defaultPublicRadiusKm,
      ifNoneMatch: ifNoneMatch,
    );
  }
}

/// No-op source for viewing a static saved local flight (own trail only).
class StaticLiveTrailsSource extends LiveTrailsSource {
  const StaticLiveTrailsSource();

  @override
  bool get supportsClubLayer => false;

  @override
  bool get supportsAuthExpiry => false;

  @override
  bool get supportsRemotePolling => false;

  @override
  Future<LiveTrailsResponse> fetch({
    required bool includeClub,
    required bool includePublic,
    double? lat,
    double? lon,
    int? radiusKm,
    String? ifNoneMatch,
  }) async {
    return const LiveTrailsResponse(flights: []);
  }
}
