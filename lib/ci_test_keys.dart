import 'package:flutter/widgets.dart';

/// Stable keys for integration / CI driver tests (locale-independent).
abstract final class FlightVisTestKeys {
  static const appLoading = ValueKey<String>('flightvis_app_loading');
  static const hub = ValueKey<String>('flightvis_hub');
  static const hubSignIn = ValueKey<String>('flightvis_hub_sign_in');
  static const hubLiveMap = ValueKey<String>('flightvis_hub_live_map');
  static const hubStartFlight = ValueKey<String>('flightvis_hub_start_flight');
  static const hubLocalFlights = ValueKey<String>('flightvis_hub_local_flights');
  static const hubSessionExpiredBanner =
      ValueKey<String>('flightvis_hub_session_expired');
  static const hubClubUnavailableBanner =
      ValueKey<String>('flightvis_hub_club_unavailable');
  static const hubStartError = ValueKey<String>('flightvis_hub_start_error');
  static const hubCheckIn = ValueKey<String>('flightvis_hub_check_in');
  static const checkinScreen = ValueKey<String>('flightvis_checkin_screen');
  static const hubFlightDetails = ValueKey<String>('flightvis_hub_flight_details');
  static const permissionsScreen = ValueKey<String>('flightvis_permissions');
  static const permissionsPrimary = ValueKey<String>('flightvis_permissions_primary');
  static const permissionsStepIndicator = ValueKey<String>('flightvis_permissions_step');
  static const permissionsDeniedMessage = ValueKey<String>('flightvis_permissions_denied');
  static const permissionsOpenSettings = ValueKey<String>('flightvis_permissions_open_settings');
  static const permissionsSkip = ValueKey<String>('flightvis_permissions_skip');
  static const permissionWarningCard = ValueKey<String>('flightvis_permission_warning_card');
  static const permissionWarningFix = ValueKey<String>('flightvis_permission_warning_fix');
  static const permissionWarningHint = ValueKey<String>('flightvis_permission_warning_hint');
  static const loginGuest = ValueKey<String>('flightvis_login_guest');
  static const loginRegister = ValueKey<String>('flightvis_login_register');
  static const loginRegisterNote = ValueKey<String>('flightvis_login_register_note');
  static const checkinContinue = ValueKey<String>('flightvis_checkin_continue');
  static const checkinManualEntry = ValueKey<String>('flightvis_checkin_manual_entry');
  static const checkinPasteField = ValueKey<String>('flightvis_checkin_paste_field');
  static const checkinPasteSubmit = ValueKey<String>('flightvis_checkin_paste_submit');
  static const tailPicker = ValueKey<String>('flightvis_tail_picker');
  static const tailStart = ValueKey<String>('flightvis_tail_start');
  static const trackingScreen = ValueKey<String>('flightvis_tracking');
  static const trackingStop = ValueKey<String>('flightvis_tracking_stop');
  static const trackingStopCancel = ValueKey<String>('flightvis_tracking_stop_cancel');
  static const trackingStopConfirm = ValueKey<String>('flightvis_tracking_stop_confirm');
  static const trailChips = ValueKey<String>('flightvis_trail_chips');
  static const trailChipClubDefault = ValueKey<String>('flightvis_trail_chip_default');
  static const trackingMap = ValueKey<String>('flightvis_tracking_map');
  static const mapLayerMine = ValueKey<String>('flightvis_map_layer_mine');
  static const mapLayerClub = ValueKey<String>('flightvis_map_layer_club');
  static const mapLayerPublic = ValueKey<String>('flightvis_map_layer_public');
  static const mapPublicRadiusButton =
      ValueKey<String>('flightvis_map_public_radius');
  static const mapPublicWaitingPosition =
      ValueKey<String>('flightvis_map_public_waiting_position');
  static const mapFollowToggle = ValueKey<String>('flightvis_map_follow_toggle');
  static const mapZoomIn = ValueKey<String>('flightvis_map_zoom_in');
  static const mapZoomOut = ValueKey<String>('flightvis_map_zoom_out');
  static const mapAttribution = ValueKey<String>('flightvis_map_attribution');
  static const mapSessionExpiredBanner =
      ValueKey<String>('flightvis_map_session_expired');
  static const mapSessionExpiredSignIn =
      ValueKey<String>('flightvis_map_session_expired_sign_in');
  static const mapPollStatusError =
      ValueKey<String>('flightvis_map_poll_status_error');
  static const mapClubDisabledHint =
      ValueKey<String>('flightvis_map_club_disabled_hint');
  static const liveMapScreen = ValueKey<String>('flightvis_live_map_screen');
  static const localFlightStartDialog =
      ValueKey<String>('flightvis_local_flight_start_dialog');
  static const localFlightTailField =
      ValueKey<String>('flightvis_local_flight_tail_field');
  static const localFlightConfirmStart =
      ValueKey<String>('flightvis_local_flight_confirm_start');
  static const localFlightScreen =
      ValueKey<String>('flightvis_local_flight_screen');
  static const localFlightNoClubNote =
      ValueKey<String>('flightvis_local_flight_no_club_note');
  static const localFlightStop =
      ValueKey<String>('flightvis_local_flight_stop');
  static const localFlightStopConfirm =
      ValueKey<String>('flightvis_local_flight_stop_confirm');
  static const localFlightsListScreen =
      ValueKey<String>('flightvis_local_flights_list');
  static const localFlightsGuestBanner =
      ValueKey<String>('flightvis_local_flights_guest_banner');
  static const localFlightsGuestDialog =
      ValueKey<String>('flightvis_local_flights_guest_dialog');
  static const localFlightsMoveToAccount =
      ValueKey<String>('flightvis_local_flights_move_to_account');
  static const localFlightsKeepOnPhone =
      ValueKey<String>('flightvis_local_flights_keep_on_phone');
  static const localFlightsLegacyDialog =
      ValueKey<String>('flightvis_local_flights_legacy_dialog');
  static const localFlightsLegacyBanner =
      ValueKey<String>('flightvis_local_flights_legacy_banner');
  static const localFlightsLegacyAdopt =
      ValueKey<String>('flightvis_local_flights_legacy_adopt');
  static const localFlightsLegacyDelete =
      ValueKey<String>('flightvis_local_flights_legacy_delete');
  static const localFlightsLegacyDeleteConfirmDialog =
      ValueKey<String>('flightvis_local_flights_legacy_delete_confirm_dialog');
  static const localFlightsLegacyDeleteConfirm =
      ValueKey<String>('flightvis_local_flights_legacy_delete_confirm');
  static const localFlightDeleteDialog =
      ValueKey<String>('flightvis_local_flight_delete_dialog');
  static const localFlightDeleteConfirm =
      ValueKey<String>('flightvis_local_flight_delete_confirm');

  static ValueKey<String> localFlightDelete(String id) =>
      ValueKey<String>('flightvis_local_flight_delete_$id');

  static ValueKey<String> mapPublicRadiusOption(int km) =>
      ValueKey<String>('flightvis_map_public_radius_$km');

  static ValueKey<String> trailChip(int? minutes) => ValueKey<String>(
        minutes == null
            ? 'flightvis_trail_chip_default'
            : 'flightvis_trail_chip_$minutes',
      );
}