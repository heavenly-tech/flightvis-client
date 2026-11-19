import 'app_localizations.dart';

/// Maps server `error` codes/messages to localized pilot strings when possible.
String localizeApiError(AppLocalizations l10n, String raw) {
  final key = raw.trim().toLowerCase();
  if (key == 'unauthorized' || key.contains('unauthorized')) {
    return l10n.errorUnauthorized;
  }
  if (key == 'check-in required' || key.contains('check-in')) {
    return l10n.pilotCheckInRequired;
  }
  if (key == 'pending approval' || key.contains('pending')) {
    return l10n.pilotPendingApproval;
  }
  return raw.isNotEmpty ? raw : l10n.errorGeneric;
}