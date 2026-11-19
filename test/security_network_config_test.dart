import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release network security disallows cleartext and user CAs (C-2)', () {
    final xml = File('android/app/src/main/res/xml/network_security_config.xml')
        .readAsStringSync();
    expect(xml, contains('cleartextTrafficPermitted="false"'));
    expect(xml, isNot(contains('src="user"')));
    expect(xml, contains('src="system"'));
  });

  test('debug network security allows emulator cleartext and user CAs', () {
    final xml = File('android/app/src/debug/res/xml/network_security_config.xml')
        .readAsStringSync();
    expect(xml, contains('cleartextTrafficPermitted="true"'));
    expect(xml, contains('src="user"'));
  });
}