import '../api/flight_vis_client.dart';
import 'app_localizations.dart';

final _rawMachineCode = RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)+$');
final _rawHttpStatus = RegExp(r'^http \d{3}$');

/// Maps a known server `reason` or `error` code to a localized pilot string,
/// returning `null` if [code] is unrecognized.
String? localizeApiReason(AppLocalizations l10n, String? code) {
  if (code == null) return null;
  final key = code.trim().toLowerCase();
  if (key.isEmpty) return null;
  switch (key) {
    case 'expired_qr':
    case 'old_step':
      return l10n.errorCheckInExpiredQr;
    case 'used_qr':
    case 'replay':
    case 'token already used':
      return l10n.errorCheckInUsedQr;
    case 'expired_claim':
      return l10n.errorCheckInExpiredClaim;
    case 'used_claim':
      return l10n.errorCheckInUsedClaim;
    case 'no_device':
    case 'device token required':
      return l10n.errorCheckInNoDevice;
    case 'invalid_device':
    case 'invalid device token':
    case 'device mismatch':
      return l10n.errorCheckInInvalidDevice;
    case 'not_cleared':
    case 'not cleared':
      return l10n.errorCheckInNotCleared;
    case 'club_mismatch':
    case 'wrong_club':
      return l10n.errorCheckInClubMismatch;
    case 'club_unavailable':
    case 'club unavailable':
      return l10n.errorCheckInClubUnavailable;
    case 'format':
    case 'forged_hmac':
    case 'invalid token':
    case 'invalid_token':
      return l10n.errorCheckInInvalidToken;
    case 'rate_limited':
    case 'rate limited':
    case 'too many attempts':
      return l10n.errorRateLimited;
    case 'guest_failed':
    case 'guest failed':
      return l10n.errorGuestSessionFailed;
    case 'device_cap':
      return l10n.errorDeviceCap;
    case 'invalid_install_id':
    case 'invalid installid':
      return l10n.errorInvalidInstallId;
    case 'not_approved':
      return l10n.errorNotApproved;
    case 'email_not_verified':
    case 'email not verified':
    case 'email_unverified':
    case 'email unverified':
      return l10n.errorEmailNotVerified;
    case 'club_visibility_requires_club':
      return l10n.errorClubVisibilityRequiresClub;
    case 'invalid tail':
    case 'invalid_tail':
      return l10n.errorInvalidTail;
    case 'expired':
      return l10n.errorMagicLinkExpired;
    case 'invalid':
      return l10n.errorMagicLinkInvalid;
    case 'weak password':
    case 'weak_password':
      return l10n.errorWeakPassword;
    case 'signup failed':
    case 'signup_failed':
      return l10n.errorSignupFailed;
    case 'no_session':
    case 'unauthorized':
      return l10n.errorUnauthorized;
    case 'check-in required':
      return l10n.pilotCheckInRequired;
    case 'pending approval':
      return l10n.pilotPendingApproval;
    case 'db_error':
    case 'db error':
    case 'check-in failed':
    case 'checkin_failed':
      return l10n.errorGeneric;
  }
  if (key.startsWith('not cleared') || key.contains('not_cleared')) {
    return l10n.errorCheckInNotCleared;
  }
  if (key.startsWith('device cap')) {
    return l10n.errorDeviceCap;
  }
  if (key.contains('unauthorized')) {
    return l10n.errorUnauthorized;
  }
  if (key.contains('check-in')) {
    return l10n.pilotCheckInRequired;
  }
  if (key.contains('pending')) {
    return l10n.pilotPendingApproval;
  }
  return null;
}

/// Maps server `error` / `reason` codes or messages to localized pilot strings.
String localizeApiError(AppLocalizations l10n, String raw) {
  final mapped = localizeApiReason(l10n, raw);
  if (mapped != null) return mapped;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return l10n.errorGeneric;
  final lower = trimmed.toLowerCase();
  if (_rawMachineCode.hasMatch(lower) || _rawHttpStatus.hasMatch(lower)) {
    return l10n.errorGeneric;
  }
  return trimmed;
}

/// Maps a [FlightVisException] to a friendly localized pilot string using the
/// server `reason` code first, then `body['error']` / `message` / status code.
String localizeApiException(AppLocalizations l10n, FlightVisException error) {
  final byReason = localizeApiReason(l10n, error.reason);
  if (byReason != null) return byReason;

  final bodyError = error.body?['error']?.toString();
  final byBodyError = localizeApiReason(l10n, bodyError);
  if (byBodyError != null) return byBodyError;

  final byMessage = localizeApiReason(l10n, error.message);
  if (byMessage != null) return byMessage;

  if (error.statusCode == 429) return l10n.errorRateLimited;
  if (error.statusCode == 401) return l10n.errorUnauthorized;

  final serverMsg = error.serverMessage?.trim();
  if (serverMsg != null &&
      serverMsg.isNotEmpty &&
      l10n.localeName.toLowerCase().startsWith('es')) {
    return serverMsg;
  }

  return localizeApiError(l10n, error.message);
}
