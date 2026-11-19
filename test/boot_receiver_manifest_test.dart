import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Future<String?> _findMergedManifest() async {
  const ciPointer = 'tool/ci_merged_manifest_path.txt';
  if (File(ciPointer).existsSync()) {
    final pointer = File(ciPointer).readAsStringSync().trim();
    if (pointer.isNotEmpty && File(pointer).existsSync()) return pointer;
  }
  const candidates = [
    'android/app/build/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml',
    'android/app/build/intermediates/merged_manifests/debug/processDebugMainManifest/AndroidManifest.xml',
    'android/app/build/intermediates/merged_manifest/debug/output/AndroidManifest.xml',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  final buildDir = Directory('android/app/build');
  if (!buildDir.existsSync()) return null;
  await for (final entity in buildDir.list(recursive: true, followLinks: false)) {
    final path = entity.path;
    if (!path.endsWith('AndroidManifest.xml')) continue;
    if (path.contains('merged_manifest')) return path;
  }
  return null;
}

void main() {
  test('BootReceiver removed from merged manifest policy (C-3)', () async {
    if (!Platform.isLinux) {
      return;
    }
    final path = await _findMergedManifest();
    if (path == null) {
      markTestSkipped(
        'merged AndroidManifest.xml missing — CI runs debug APK build before flutter test',
      );
      return;
    }
    final xml = File(path).readAsStringSync();
    // Merged output must not register Traccar BootReceiver (C-3 remove merge rule).
    expect(xml, isNot(contains('org.traccar.client.BootReceiver')));
  });
}