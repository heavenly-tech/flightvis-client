import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Visual classification of a rendered aircraft / trail layer on the pilot map.
enum MapTrailKind { own, club, public }

/// High-contrast, sunlight-readable palette and stroke configuration for map trails.
abstract final class TrailPalette {
  /// Own aircraft: vivid safety orange-red with crisp white halo.
  static const Color ownColor = Color(0xFFF94E17);
  static const Color ownBadgeBackground = Color(0xFFD63B0A);

  /// Club aircraft: high-contrast aviation blue.
  static const Color clubColor = Color(0xFF0B66D6);
  static const Color clubBadgeBackground = Color(0xFFFFFFFF);

  /// Public aircraft: distinct muted slate-purple (dashed/thinner).
  static const Color publicColor = Color(0xFF6B5B95);
  static const Color publicBadgeBackground = Color(0xFFF4F1F8);

  /// Subtle land-tinted canvas background behind map tiles.
  static const Color mapCanvasBackground = Color(0xFFEAF0E8);
}

/// Builds the canonical `layers` query value for `GET /api/me/live-trails`.
///
/// Returns `null` when both [includeClub] and [includePublic] are `false`
/// (callers must NOT make any HTTP request in that case).
String? buildLiveTrailsLayersParam({
  required bool includeClub,
  required bool includePublic,
}) {
  if (!includeClub && !includePublic) return null;
  if (includeClub && includePublic) return 'club,public';
  if (includeClub) return 'club';
  return 'public';
}

/// Splits a chronological list of [points] (oldest → newest) into up to
/// [maxBuckets] contiguous sub-polylines with monotonically increasing opacity
/// so older segments fade smoothly even on circular turns / thermals.
List<Polyline> buildFadedTrailPolylines({
  required List<LatLng> points,
  required MapTrailKind kind,
  List<int>? timestampsMs,
  int maxBuckets = 8,
}) {
  if (points.length < 2) return const [];

  final (
    Color baseColor,
    double strokeWidth,
    double borderWidth,
    double minAlpha,
    double maxAlpha,
    StrokePattern pattern,
  ) = switch (kind) {
    MapTrailKind.own => (
        TrailPalette.ownColor,
        5.0,
        2.5,
        0.28,
        1.0,
        const StrokePattern.solid(),
      ),
    MapTrailKind.club => (
        TrailPalette.clubColor,
        3.5,
        1.4,
        0.22,
        0.92,
        const StrokePattern.solid(),
      ),
    MapTrailKind.public => (
        TrailPalette.publicColor,
        2.4,
        0.8,
        0.20,
        0.78,
        StrokePattern.dashed(segments: const [8, 6]),
      ),
  };

  final segmentCount = points.length - 1;
  final bucketCount = math.min(math.max(1, maxBuckets), segmentCount);
  final hasValidTimes = timestampsMs != null &&
      timestampsMs.length == points.length &&
      timestampsMs.last > timestampsMs.first;
  final minT = hasValidTimes ? timestampsMs.first : 0;
  final spanT = hasValidTimes ? (timestampsMs.last - minT).toDouble() : 1.0;

  final halos = <Polyline>[];
  final cores = <Polyline>[];
  for (var b = 0; b < bucketCount; b++) {
    final startIdx = (b * segmentCount) ~/ bucketCount;
    final endIdx = ((b + 1) * segmentCount) ~/ bucketCount;
    if (endIdx <= startIdx) continue;

    final slice = points.sublist(startIdx, endIdx + 1);
    final double progress;
    if (bucketCount == 1) {
      progress = 1.0;
    } else if (hasValidTimes) {
      final midTime = (timestampsMs[startIdx] + timestampsMs[endIdx]) / 2.0;
      progress = ((midTime - minT) / spanT).clamp(0.0, 1.0);
    } else {
      progress = b / (bucketCount - 1);
    }

    final alpha = minAlpha + (maxAlpha - minAlpha) * progress;
    final borderAlpha = kind == MapTrailKind.own
        ? (0.35 + 0.60 * progress)
        : (0.18 + 0.50 * progress);

    if (borderWidth > 0) {
      halos.add(
        Polyline(
          points: slice,
          strokeWidth: strokeWidth + borderWidth * 2,
          color: Colors.white.withValues(alpha: borderAlpha),
          pattern: pattern,
          strokeCap: b == bucketCount - 1 ? StrokeCap.round : StrokeCap.butt,
          strokeJoin: StrokeJoin.round,
        ),
      );
    }

    cores.add(
      Polyline(
        points: slice,
        strokeWidth: strokeWidth,
        color: baseColor.withValues(alpha: alpha),
        pattern: pattern,
        strokeCap: b == bucketCount - 1 ? StrokeCap.round : StrokeCap.butt,
        strokeJoin: StrokeJoin.round,
      ),
    );
  }
  return [...halos, ...cores];
}
