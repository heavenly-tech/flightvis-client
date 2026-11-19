import 'package:flutter/widgets.dart';

import '../state/checkin_gate.dart';
import 'app_localizations.dart';

extension PilotL10n on BuildContext {
  AppLocalizations get pilotL10n => AppLocalizations.of(this)!;
}

String? checkinBlockMessage(AppLocalizations l10n, CheckinStartBlock? block) {
  return switch (block) {
    CheckinStartBlock.missing => l10n.pilotCheckInRequired,
    CheckinStartBlock.expired => l10n.pilotCheckInExpired,
    null => null,
  };
}