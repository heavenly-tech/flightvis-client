import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/app_config.dart';
import 'package:flight_vis/storage/preferences_store.dart';

void main() {
  test('release builds ignore persisted base URL override (C-1)', () {
    final effective = PreferencesStore.effectiveBaseUrl(
      saved: 'https://evil.example',
      releaseMode: true,
    );
    expect(effective, AppConfig.normalizeBaseUrl(AppConfig.defaultBaseUrl));
    expect(effective, isNot(contains('evil')));
  });

  test('debug builds honor persisted base URL override', () {
    expect(
      PreferencesStore.effectiveBaseUrl(
        saved: 'https://club.example',
        releaseMode: false,
      ),
      'https://club.example',
    );
  });
}