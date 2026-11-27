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
  final exportedAppComponents = RegExp(
    r'<(activity|service|receiver)\b[^>]*android:name="([^"]+)"[^>]*android:exported\s*=\s*"true"',
    caseSensitive: false,
  ).allMatches(xml);
  for (final match in exportedAppComponents) {
    final name = match.group(2)!;
    if (!name.startsWith('cl.heavenly.flightvis') && !name.startsWith('.')) {
      continue;
    }
    expect(
      name == 'cl.heavenly.flightvis.MainActivity' || name == '.MainActivity',
      isTrue,
      reason: 'only MainActivity may be exported in app package (found $name)',
    );
  }
}

void main() {
  test('source AndroidManifest declares battery exemption, notifications, and non-exported local recorder service', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      xml,
      contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'),
    );
    expect(xml, contains('android.permission.POST_NOTIFICATIONS'));
    expect(xml, contains('android.permission.INTERNET'));
    expect(xml, contains('android.permission.FOREGROUND_SERVICE_LOCATION'));
    expect(xml, contains('android:name=".LocalFlightRecorderService"'));
    expect(xml, contains('android:foregroundServiceType="location"'));
    expect(xml, contains('android:pathPrefix="/api/club/auth/magic"'));
    expect(xml, contains('android:pathPrefix="/api/account/auth/magic"'));
    expect(
      RegExp(
        r'<intent-filter[^>]*android:autoVerify="true"[\s\S]*?android:host="flight\.heavenly\.cl"[\s\S]*?android:pathPrefix="/api/account/auth/magic"[\s\S]*?</intent-filter>',
      ).hasMatch(xml),
      isTrue,
      reason: 'AndroidManifest must claim https://flight.heavenly.cl/api/account/auth/magic with autoVerify="true"',
    );
    _expectExportPolicy(xml);
  });

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
    expect(xml, contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
    expect(xml, contains('android.permission.POST_NOTIFICATIONS'));
    expect(xml, contains('TrackerService'));
    expect(xml, isNot(contains('org.traccar.client.BootReceiver')));
    _expectNoBootCompletedReceivers(xml);
    _expectExportPolicy(xml);
  });
}