import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

bool _isCi() =>
    Platform.environment['CI'] == 'true' ||
    Platform.environment['GITHUB_ACTIONS'] == 'true';

Future<String?> _findMergedManifest() async {
  const ciPointer = 'tool/ci_merged_manifest_path.txt';
  if (File(ciPointer).existsSync()) {
    final pointer = File(ciPointer).readAsStringSync().trim();
    if (pointer.isNotEmpty && File(pointer).existsSync()) return pointer;
  }
  const candidates = [
    'build/app/intermediates/merged_manifests/debug/processDebugMainManifest/AndroidManifest.xml',
    'build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void _expectExportPolicy(String xml) {
  final exportedTrue = RegExp(r'android:exported\s*=\s*"true"', caseSensitive: false)
      .allMatches(xml)
      .length;
  expect(
    exportedTrue,
    1,
    reason: 'only MainActivity should be exported=true',
  );
  expect(
    xml,
    isNot(matches(RegExp(r'<receiver[^>]*android:exported\s*=\s*"true"', caseSensitive: false))),
  );
}

void main() {
  test('C-3 merged debug manifest policy (BootReceiver / BOOT_COMPLETED / export)', () async {
    if (!Platform.isLinux) return;

    final path = await _findMergedManifest();
    if (path == null) {
      if (_isCi()) {
        fail('merged AndroidManifest.xml missing — expected tool/ci_merged_manifest_path.txt');
      }
      markTestSkipped('merged AndroidManifest.xml missing locally');
      return;
    }

    final xml = File(path).readAsStringSync();
    expect(xml, contains('package="cl.heavenly.flightvis"'));
    expect(xml, contains('TrackerService'));
    expect(xml, isNot(contains('org.traccar.client.BootReceiver')));
    expect(xml, isNot(contains('BOOT_COMPLETED')));
    _expectExportPolicy(xml);
  });
}