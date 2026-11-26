import 'flight_permissions.dart';

/// Models the single-button "Corregir" permission walk-through in fixed order:
/// `fineLocation -> backgroundLocation -> notifications -> battery`.
///
/// Tracks the last attempted gap so the UI can show an OEM guidance hint if the
/// user returns from system settings and the same gap is still missing.
class PermissionFixFlow {
  PermissionFixFlow({required this.client});

  final FlightPermissionsClient client;

  PermissionGap? _lastAttemptedGap;
  PermissionGap? _stuckGap;

  PermissionGap? get lastAttemptedGap => _lastAttemptedGap;

  /// Non-null when the user attempted to fix this gap and it remained missing.
  PermissionGap? get stuckGap => _stuckGap;

  /// Returns the first missing permission gap in canonical walk-through order,
  /// or `null` when all permissions are granted.
  static PermissionGap? nextGapToFix(FlightPermissionStatus status) {
    if (!status.fineLocationGranted) return PermissionGap.fineLocation;
    if (!status.backgroundLocationGranted) {
      return PermissionGap.backgroundLocation;
    }
    if (!status.notificationsGranted) return PermissionGap.notifications;
    if (!status.batteryUnrestricted) return PermissionGap.battery;
    return null;
  }

  /// Launches the fix action for the first missing gap in [current], then
  /// re-checks status and updates [stuckGap].
  Future<FlightPermissionStatus> fixNext(FlightPermissionStatus current) async {
    final target = nextGapToFix(current);
    if (target == null) {
      _lastAttemptedGap = null;
      _stuckGap = null;
      return current;
    }
    _lastAttemptedGap = target;
    await client.openGapSettings(target);
    final updated = await client.check();
    onStatusChecked(updated);
    return updated;
  }

  /// Updates hint state when permissions are re-checked (e.g. on app resume).
  void onStatusChecked(FlightPermissionStatus updated) {
    final attempted = _lastAttemptedGap;
    if (attempted == null) {
      _stuckGap = null;
      return;
    }
    if (updated.isGapGranted(attempted)) {
      _lastAttemptedGap = null;
      _stuckGap = null;
    } else {
      _stuckGap = attempted;
    }
  }
}
