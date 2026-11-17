import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Club check-in expiry display (server `expiresAt` only; [America/Santiago]).
class CheckinExpiryFormat {
  static const locationName = 'America/Santiago';
  static bool _ready = false;

  static void ensureInitialized() {
    if (_ready) return;
    tz_data.initializeTimeZones();
    _ready = true;
  }

  static tz.Location get _santiago => tz.getLocation(locationName);

  /// UTC instant from server → local label (time only if today in Santiago, else date + time).
  static String formatFromUtc(DateTime expiresAtUtc) {
    final utc = expiresAtUtc.toUtc();
    final atClub = tz.TZDateTime.from(utc, _santiago);
    final nowClub = tz.TZDateTime.now(_santiago);
    final sameDay =
        atClub.year == nowClub.year && atClub.month == nowClub.month && atClub.day == nowClub.day;
    if (sameDay) {
      return DateFormat('HH:mm').format(
        DateTime(atClub.year, atClub.month, atClub.day, atClub.hour, atClub.minute),
      );
    }
    return DateFormat('d MMM HH:mm').format(
      DateTime(atClub.year, atClub.month, atClub.day, atClub.hour, atClub.minute),
    );
  }

  static String formatFromEpochMs(int expiresAtMs) =>
      formatFromUtc(DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true));
}