import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable per-install id for `POST /api/me/devices` (server PR #15).
class DeviceInstallId {
  static const _prefsKey = 'fv_install_id';

  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && saved.length >= 8) return saved;
    final info = DeviceInfoPlugin();
    final android = await info.androidInfo;
    final id = 'fv-${android.id}';
    await prefs.setString(_prefsKey, id);
    return id;
  }
}