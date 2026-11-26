import 'package:flutter_map/flutter_map.dart';

/// Immutable configuration for raster map tiles and required attribution.
class MapTileConfig {
  const MapTileConfig({
    required this.urlTemplate,
    required this.attribution,
    required this.attributionSource,
    required this.attributionUri,
    required this.userAgentPackageName,
    this.minZoom = 3,
    this.maxZoom = 19,
    this.maxNativeZoom = 19,
  });

  final String urlTemplate;

  /// Full required attribution text (per OSM Tile Usage Policy).
  final String attribution;

  /// Source text passed to [SimpleAttributionWidget] (which renders `© `).
  final String attributionSource;

  /// Copyright/attribution page URL.
  final String attributionUri;

  /// Android `applicationId` sent in the HTTP `User-Agent` header.
  final String userAgentPackageName;

  final double minZoom;
  final double maxZoom;
  final int maxNativeZoom;
}

/// OpenStreetMap standard tile layer configuration.
///
/// Esri ArcGIS World Imagery requires an ArcGIS account/API key for native app
/// usage; we therefore use OpenStreetMap standard tiles over HTTPS with the app
/// package ID in `User-Agent`, zero prefetching (`panBuffer: 0`), and permanent
/// visible attribution per the OSM Tile Usage Policy.
const kOsmTileConfig = MapTileConfig(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: '© OpenStreetMap contributors',
  attributionSource: 'OpenStreetMap contributors',
  attributionUri: 'https://www.openstreetmap.org/copyright',
  userAgentPackageName: 'cl.heavenly.flightvis',
);

/// Test hook allowing deterministic widget/golden tests to override the map
/// [TileProvider] without hitting the network (mirrors `DeepLinkTestHooks`).
abstract final class TrackingMapTestHooks {
  static TileProvider? tileProviderOverride;
}
