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

void _expectNoBootCompletedReceivers(String xml) {
  final receivers = RegExp(r'<receiver\b[\s\S]*?</receiver>', multiLine: true).allMatches(xml);
  for (final block in receivers) {
    expect(block.group(0), isNot(contains('BOOT_COMPLETED')));
  }
}

void _expectExportPolicy(String xml) {
  expect(
    xml,
    isNot(matches(RegExp(r'<(service|receiver)\b[^>]*android:exported\s*=\s*"true"', caseSensitive: false))),
  );
  expect(
    xml,
    matches(RegExp(
      r'<activity\b[^>]*android:name="\.MainActivity"[^>]*android:exported\s*=\s*"true"',
      caseSensitive: false,
    )),
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
    _expectNoBootCompletedReceivers(xml);
    _expectExportPolicy(xml);
  });
}