import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/spanish_voseo.dart';

void main() {
  group('voseo detector examples', () {
    test('flags Rioplatense present -ás/-és/-ís voseo forms', () {
      for (final word in [
        'podés',
        'tenés',
        'querés',
        'sabés',
        'hacés',
        'decís',
        'venís',
        'elegís',
        'volás',
        'usás',
        'tocás',
        'mirás',
        'esperás',
        'entrás',
        'cerrás',
      ]) {
        expect(
          findSpanishVoseoViolations('Ahora $word continuar.'),
          contains('present:$word'),
          reason: 'Expected present voseo violation for "$word"',
        );
      }
    });

    test('flags Chilean present -ís voseo forms', () {
      for (final word in [
        'podís',
        'tenís',
        'querís',
        'sabís',
      ]) {
        expect(
          findSpanishVoseoViolations('Ahora $word volar.'),
          contains('present:$word'),
          reason: 'Expected Chilean -ís voseo violation for "$word"',
        );
      }
    });

    test('flags voseo imperatives including final stressed vowel and fijate', () {
      for (final word in [
        'tené',
        'mirá',
        'hacé',
        'vení',
        'decí',
        'poné',
        'andá',
        'fijate',
        'creá',
        'tocá',
        'escaneá',
        'elegí',
        'permití',
      ]) {
        expect(
          findSpanishVoseoViolations('$word el ajuste antes de volar.'),
          contains('imperative:$word'),
          reason: 'Expected voseo imperative violation for "$word"',
        );
      }
    });

    test('flags standalone pronoun vos without flagging words containing vos', () {
      expect(findSpanishVoseoViolations('vos puedes'), contains('pronoun:vos'));
      expect(findSpanishVoseoViolations('Para vos.'), contains('pronoun:vos'));
      expect(findSpanishVoseoViolations('Vos elegís.'), contains('pronoun:Vos'));
      expect(
        findSpanishVoseoViolations('Administra tus dispositivos nuevos y activos.'),
        isEmpty,
      );
    });

    test('allows tú future forms ending in -rás', () {
      for (final future in [
        'podrás',
        'tendrás',
        'querrás',
        'sabrás',
        'harás',
        'dirás',
        'vendrás',
        'pondrás',
        'subirás',
        'guardarás',
        'volarás',
        'usarás',
        'verás',
        'serás',
        'darás',
        'irás',
        'saldrás',
        'habrás',
        'valdrás',
        'cabrás',
        'obtendrás',
        'dispondrás',
        'esperarás',
        'mirarás',
        'entrarás',
      ]) {
        expect(
          isSpanishTuFuture(future),
          isTrue,
          reason: 'Expected isSpanishTuFuture("$future") == true',
        );
        expect(
          findSpanishVoseoViolations('Pronto $future hacerlo.'),
          isEmpty,
          reason: 'Unexpected voseo violation for tú future "$future"',
        );
      }
    });

    test('allows restored localFlightNoClubNote with tú future podrás', () {
      expect(
        findSpanishCopyViolations(
          'Vuelo sin club: se guarda en tu teléfono. Pronto podrás subirlo.',
        ),
        isEmpty,
      );
    });

    test('allows neutral tú forms and standard accented Spanish words', () {
      for (final word in [
        'más',
        'además',
        'atrás',
        'jamás',
        'detrás',
        'quizás',
        'demás',
        'está',
        'estás',
        'estés',
        'sí',
        'aquí',
        'allí',
        'país',
        'también',
        'café',
        'José',
        'será',
        'después',
        'través',
        'revés',
        'inglés',
        'francés',
        'interés',
        'fíjate',
      ]) {
        expect(
          findSpanishVoseoViolations('Ejemplo con $word en la frase.'),
          isEmpty,
          reason: 'Unexpected voseo violation for legitimate word "$word"',
        );
      }

      expect(
        findSpanishVoseoViolations(
          'Crea tu cuenta con tu correo; puedes continuar cuando quieras.',
        ),
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

    expect(
      map['localFlightNoClubNote'],
      'Vuelo sin club: se guarda en tu teléfono. Pronto podrás subirlo.',
    );

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
