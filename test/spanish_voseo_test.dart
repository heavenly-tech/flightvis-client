import 'dart:convert';
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

  group('usted detector examples', () {
    test('flags common usted imperatives and possessives', () {
      for (final sample in [
        'Use passkey para entrar.',
        'Escanee el QR del club.',
        'Inicie sesión para guardar historial.',
        'Pegue el código aquí.',
        'Elija matrícula y visibilidad.',
        'Seleccione una matrícula.',
        'Revise los permisos de ubicación.',
        'Desactive la optimización de batería.',
        'Vincule este teléfono con su cuenta.',
        'Falta el código — vincúlelo primero.',
        'Si el correo está registrado, le enviamos un enlace.',
        'Debe activar ubicación todo el tiempo.',
        'No puede comenzar sin ubicación.',
        'Puede cambiar la URL predeterminada.',
        'Inténtelo de nuevo.',
      ]) {
        expect(
          findSpanishUstedViolations(sample),
          isNotEmpty,
          reason: 'Expected usted violation in: "$sample"',
        );
      }
    });

    test('allows es-CL tú copy and third-person subjects', () {
      for (final sample in [
        'Usa passkey, enlace mágico o contraseña. También puedes continuar sin iniciar sesión.',
        'Escanea el QR de la pantalla del club',
        'Elige matrícula y visibilidad, luego comienza',
        'Selecciona una matrícula.',
        'Inténtalo de nuevo.',
        'El club aún no te habilita. Pídele al administrador que apruebe tu cuenta.',
        'Para transmitir tu posición durante el vuelo, flight_vis necesita ubicación en segundo plano.',
      ]) {
        expect(
          findSpanishUstedViolations(sample),
          isEmpty,
          reason: 'Unexpected usted violation in: "$sample"',
        );
      }
    });
  });

  group('anglicism detector examples', () {
    test('flags check-in, tracking, and token', () {
      expect(findSpanishAnglicismViolations('QR de check-in'), isNotEmpty);
      expect(findSpanishAnglicismViolations('Finalizar tracking'), isNotEmpty);
      expect(findSpanishAnglicismViolations('Guardar token'), isNotEmpty);
      expect(findSpanishAnglicismViolations('Tokens inválidos'), isNotEmpty);
    });

    test('allows passkey and Spanish replacements', () {
      expect(
        findSpanishAnglicismViolations(
          'Usa passkey, escanea el QR de registro, guarda el código y comienza el seguimiento.',
        ),
        isEmpty,
      );
    });
  });

  test('app_es.arb values have no voseo, usted, or forbidden anglicisms', () {
    final file = File('lib/l10n/app_es.arb');
    expect(file.existsSync(), isTrue);
    final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

    final failures = <String>[];
    for (final entry in map.entries) {
      if (entry.key.startsWith('@') || entry.key.startsWith('@@')) continue;
      final value = entry.value;
      if (value is! String) continue;
      final hits = findSpanishCopyViolations(value);
      if (hits.isNotEmpty) {
        failures.add('${entry.key}: "$value" -> ${hits.join(', ')}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('Android values/strings.xml has no voseo, usted, or forbidden anglicisms', () {
    final file = File('android/app/src/main/res/values/strings.xml');
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    final re = RegExp(r'<string[^>]*>([^<]+)</string>');
    final failures = <String>[];
    for (final m in re.allMatches(text)) {
      final value = m.group(1)!;
      final hits = findSpanishCopyViolations(value);
      if (hits.isNotEmpty) {
        failures.add('"$value" -> ${hits.join(', ')}');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
