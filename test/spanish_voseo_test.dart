import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/spanish_voseo.dart';

void main() {
  group('voseo detector examples', () {
    test('flags imperative creá', () {
      expect(
        findSpanishVoseoViolations('Creá tu cuenta con tu correo.'),
        isNotEmpty,
      );
    });

    test('flags present podés', () {
      expect(findSpanishVoseoViolations('podés continuar'), contains('present:podés'));
    });

    test('flags pronoun vos', () {
      expect(findSpanishVoseoViolations('vos podés'), isNotEmpty);
    });

    test('allows neutral Crea and puedes', () {
      expect(
        findSpanishVoseoViolations(
          'Crea tu cuenta con tu correo; puedes continuar cuando quieras.',
        ),
        isEmpty,
      );
    });

    test('allows allowlisted está and más', () {
      expect(
        findSpanishVoseoViolations('Si el correo está registrado, hay más opciones aquí.'),
        isEmpty,
      );
    });

    test('allows allowlisted quizás and inglés', () {
      expect(
        findSpanishVoseoViolations('Quizás prefiera inglés o francés.'),
        isEmpty,
      );
    });
  });

  test('app_es.arb has no voseo', () {
    final file = File('lib/l10n/app_es.arb');
    expect(file.existsSync(), isTrue);
    final content = file.readAsStringSync();
    expect(findSpanishVoseoViolations(content), isEmpty);
  });
}