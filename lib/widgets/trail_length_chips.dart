import 'package:flutter/material.dart';

import '../ci_test_keys.dart';
import '../l10n/app_localizations.dart';
import '../l10n/pilot_l10n.dart';

/// Allowed per-flight trail length options (`null` = club default).
///
/// Encoding matches the server API:
/// - `null`: use the club default
/// - `0`: off ("No")
/// - `2, 5, 10, 15, 30`: minutes
/// - `-1`: full flight ("Todo")
const List<int?> trailLengthOptions = <int?>[null, 0, 2, 5, 10, 15, 30, -1];

/// Formats a non-null trail length integer using the active [AppLocalizations].
String formatTrailMinutesOption(AppLocalizations l10n, int minutes) {
  if (minutes == 0) return l10n.pilotTrailOff;
  if (minutes == -1) return l10n.pilotTrailAll;
  return l10n.pilotTrailMinutes(minutes);
}

/// Reusable chip selector for per-flight live trail length ("Estela").
class TrailLengthChips extends StatelessWidget {
  const TrailLengthChips({
    super.key,
    required this.selectedMinutes,
    required this.onSelected,
    this.clubDefaultMinutes,
    this.enabled = true,
  });

  /// Selected trail override (`null` means use the club default).
  final int? selectedMinutes;

  /// Invoked when the pilot taps one of the trail options.
  final ValueChanged<int?> onSelected;

  /// Optional club default trail length from `GET /api/club/me`.
  final int? clubDefaultMinutes;

  /// Whether chips respond to taps.
  final bool enabled;

  String _chipLabel(AppLocalizations l10n, int? option) {
    if (option == null) {
      final clubDefault = clubDefaultMinutes;
      if (clubDefault != null && clubDefault >= -1) {
        return l10n.pilotTrailClubDefaultWithValue(
          formatTrailMinutesOption(l10n, clubDefault),
        );
      }
      return l10n.pilotTrailClubDefault;
    }
    return formatTrailMinutesOption(l10n, option);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.pilotL10n;
    final theme = Theme.of(context);
    return Column(
      key: FlightVisTestKeys.trailChips,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.pilotTrailTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.pilotTrailHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in trailLengthOptions)
              _buildChip(l10n, option),
          ],
        ),
      ],
    );
  }

  Widget _buildChip(AppLocalizations l10n, int? option) {
    final label = _chipLabel(l10n, option);
    final selected = selectedMinutes == option;
    return ChoiceChip(
      key: FlightVisTestKeys.trailChip(option),
      label: Semantics(
        label: l10n.pilotTrailChipSemantic(label),
        excludeSemantics: true,
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
      selected: selected,
      onSelected: enabled ? (_) => onSelected(option) : null,
    );
  }
}
