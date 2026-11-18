import 'package:flutter/widgets.dart';

/// Stable keys for integration / CI driver tests (locale-independent).
abstract final class FlightVisTestKeys {
  static const appLoading = ValueKey<String>('flightvis_app_loading');
  static const hub = ValueKey<String>('flightvis_hub');
  static const hubSignIn = ValueKey<String>('flightvis_hub_sign_in');
  static const hubCheckIn = ValueKey<String>('flightvis_hub_check_in');
  static const checkinScreen = ValueKey<String>('flightvis_checkin_screen');
  static const hubFlightDetails = ValueKey<String>('flightvis_hub_flight_details');
  static const permissionsScreen = ValueKey<String>('flightvis_permissions');
  static const permissionsPrimary = ValueKey<String>('flightvis_permissions_primary');
  static const loginGuest = ValueKey<String>('flightvis_login_guest');
  static const checkinContinue = ValueKey<String>('flightvis_checkin_continue');
  static const tailPicker = ValueKey<String>('flightvis_tail_picker');
  static const tailStart = ValueKey<String>('flightvis_tail_start');
  static const trackingScreen = ValueKey<String>('flightvis_tracking');
  static const trackingStop = ValueKey<String>('flightvis_tracking_stop');
}