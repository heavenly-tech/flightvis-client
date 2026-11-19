import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<String?> _findMergedManifest() async {
  const candidates = [
    'android/app/build/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml',
    'android/app/build/intermediates/merged_manifests/debug/AndroidManifest.xml',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  final root = Directory('android/app/build/intermediates');
  if (!root.existsSync()) return null;
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    final path = entity.path;
    if (path.contains('merged_manifest') && path.endsWith('AndroidManifest.xml')) {
      return path;
    }
  }
  return null;
}

void main() {
  test('BootReceiver removed from merged manifest policy (C-3)', () async {
    if (!Platform.isLinux) {
      return;
    }
    var path = await _findMergedManifest();
    if (path == null) {
      final gradlew = File('android/gradlew');
      if (gradlew.existsSync()) {
        final gradle = await Process.run(
          gradlew.path,
          [':app:processDebugMainManifest'],
          workingDirectory: 'android',
        );
        expect(gradle.exitCode, 0, reason: '${gradle.stdout}\n${gradle.stderr}');
        path = await _findMergedManifest();
      }
    }
    if (path == null) {
      markTestSkipped(
        'merged AndroidManifest.xml missing — CI builds a debug APK before flutter test',
      );
      return;
    }
    final xml = File(path).readAsStringSync();
    expect(xml, contains('org.traccar.client.BootReceiver'));
    expect(xml, contains('tools:node="remove"'));
  });
}