import 'package:flutter_test/flutter_test.dart';

import 'package:flight_vis/util/tail_format.dart';

void main() {
  test('accepts CC-XXX', () {
    expect(validateChileTail('cc-abc'), isNull);
    expect(normalizeChileTail('cc-abc'), 'CC-ABC');
  });

  test('rejects invalid tail', () {
    expect(validateChileTail('N12345'), isNotNull);
    expect(validateChileTail('CC-12'), isNotNull);
  });
}