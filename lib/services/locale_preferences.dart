import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';

/// Persisted in-app language override (`es`, `en`, or system default).
class LocalePreferences {
  LocalePreferences(this._prefs);

  static const languageKey = 'fv_language_override';

  final SharedPreferences _prefs;

  /// `null` = follow device; otherwise `es` or `en`.
  String? languageOverride() {
    final raw = _prefs.getString(languageKey);
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  Future<void> setLanguageOverride(String? languageCode) async {
    if (languageCode == null || languageCode.isEmpty) {
      await _prefs.remove(languageKey);
    } else {
      await _prefs.setString(languageKey, languageCode);
    }
  }

  Locale resolveLocale(Locale? deviceLocale) {
    if (AppConfig.screenshotTest) return const Locale('es', 'CL');
    final override = languageOverride();
    if (override == 'en') return const Locale('en');
    if (override == 'es') return const Locale('es', 'CL');
    final device = deviceLocale;
    if (device != null) {
      if (device.languageCode == 'en') return const Locale('en');
      if (device.languageCode == 'es') return Locale('es', device.countryCode ?? 'CL');
    }
    return const Locale('es', 'CL');
  }

  /// BCP 47 tag for API headers (`user.locale` / Accept-Language).
  String apiLocaleTag(Locale locale) {
    if (locale.languageCode == 'en') return 'en';
    return 'es-CL';
  }
}