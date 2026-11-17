import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BootReceiver removed from merged manifest policy (C-3)', () {
    final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(xml, contains('org.traccar.client.BootReceiver'));
    expect(xml, contains('tools:node="remove"'));
  });
}