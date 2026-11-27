/// Detects voseo (Rioplatense and Chilean), usted register, and forbidden
/// anglicisms in es-CL UI copy while allowing standard Spanish `tú` futures
/// in `-rás` and legitimate accented Spanish words.
library;

/// Legitimate Spanish words ending in `-ás`/`-és`/`-ís` or final stressed
/// vowels that must never be flagged as voseo.
final Set<String> spanishVoseoAllowlist = {
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
  'será',
  'sí',
  'aquí',
  'allí',
  'país',
  'también',
  'café',
  'josé',
  'después',
  'través',
  'revés',
  'estrés',
  'interés',
  'desinterés',
  'inglés',
  'francés',
  'portugués',
  'japonés',
  'holandés',
  'irlandés',
  'escocés',
  'cortés',
  'descortés',
  'exprés',
  'compás',
  'veintitrés',
  'parís',
  'anís',
  'arnés',
  'ciprés',
  'marqués',
  'burgués',
  'andrés',
  'inés',
  'moisés',
  'ciempiés',
  'traspiés',
};

/// Explicit allowlist of irregular Spanish `tú` future forms ending in `-rás`
/// (including prefixed compounds such as `obtendrás`, `dispondrás`, `desharás`,
/// `satisfarás`, `preverás`).
const Set<String> spanishIrregularTuFutureRoots = {
  'podrás',
  'tendrás',
  'querrás',
  'sabrás',
  'harás',
  'dirás',
  'vendrás',
  'pondrás',
  'saldrás',
  'valdrás',
  'habrás',
  'cabrás',
};

/// Prefixed compounds of irregular Spanish `tú` futures and short forms whose
/// stem does not follow `<infinitive> + ás`.
const Set<String> spanishIrregularTuFutureCompounds = {
  'obtendrás',
  'mantendrás',
  'contendrás',
  'detendrás',
  'sostendrás',
  'retendrás',
  'entretendrás',
  'dispondrás',
  'propondrás',
  'supondrás',
  'repondrás',
  'expondrás',
  'impondrás',
  'compondrás',
  'opondrás',
  'pospondrás',
  'desharás',
  'reharás',
  'satisfarás',
  'contradirás',
  'predirás',
  'convendrás',
  'prevendrás',
  'provendrás',
  'intervendrás',
  'sobresaldrás',
  'equivaldrás',
  'prevaldrás',
  'preverás',
  'reverás',
  'entreverás',
};

/// Explicit allowlist of Spanish infinitives (`-ar`, `-er`, `-ir`) whose
/// regular `tú` future is formed strictly as `<infinitive> + 'ás'` (e.g.
/// `subir` -> `subirás`, `generar` -> `generarás`, `operar` -> `operarás`,
/// `recuperar` -> `recuperarás`).
///
/// Replaces the overly broad `[aei]rás` regex (L-85), which falsely exempted
/// `-rar` voseo presents such as `generás`, `operás`, and `recuperás` whose
/// `-ás`-stripped stems (`gener`, `oper`, `recuper`) end in `er`/`ar`/`ir`
/// without being infinitives.
const Set<String> spanishRegularFutureInfinitives = {
  // Short / core verbs
  'ir',
  'ser',
  'ver',
  'dar',
  'estar',
  // Flight / app domain & common Spanish regular verbs
  'abrir',
  'acceder',
  'acelerar',
  'aceptar',
  'activar',
  'actualizar',
  'agarrar',
  'agregar',
  'ahorrar',
  'añadir',
  'aparecer',
  'aplicar',
  'aprobar',
  'aprovechar',
  'asegurar',
  'avanzar',
  'ayudar',
  'borrar',
  'buscar',
  'cambiar',
  'cancelar',
  'cargar',
  'cerrar',
  'comenzar',
  'compartir',
  'completar',
  'comprar',
  'comprobar',
  'conceder',
  'conectar',
  'configurar',
  'confirmar',
  'conseguir',
  'consultar',
  'continuar',
  'crear',
  'curar',
  'decidir',
  'declarar',
  'dejar',
  'desactivar',
  'descargar',
  'desconectar',
  'durar',
  'elegir',
  'eliminar',
  'empezar',
  'encontrar',
  'entrar',
  'enviar',
  'escanear',
  'escribir',
  'esperar',
  'excluir',
  'finalizar',
  'generar',
  'girar',
  'grabar',
  'guardar',
  'habilitar',
  'ignorar',
  'ingresar',
  'iniciar',
  'instalar',
  'intentar',
  'leer',
  'limpiar',
  'llegar',
  'llevar',
  'llorar',
  'lograr',
  'mejorar',
  'mirar',
  'mostrar',
  'necesitar',
  'notificar',
  'ocultar',
  'operar',
  'parar',
  'pasar',
  'pedir',
  'pegar',
  'perder',
  'permitir',
  'preparar',
  'presionar',
  'probar',
  'quedar',
  'quitar',
  'recibir',
  'recuperar',
  'registrar',
  'regresar',
  'reintentar',
  'renovar',
  'revisar',
  'sacar',
  'seguir',
  'seleccionar',
  'sincronizar',
  'sobrar',
  'solicitar',
  'subir',
  'terminar',
  'tirar',
  'tocar',
  'tomar',
  'traer',
  'transmitir',
  'unir',
  'usar',
  'verificar',
  'vincular',
  'volar',
  'volver',
};

/// Returns true ONLY when [word] is an explicitly allowlisted Spanish `tú`
/// future form (irregular roots/compounds, or `<allowlisted infinitive> + 'ás'`).
///
/// Rejects `-rar` present-tense voseo forms such as `generás`, `operás`,
/// `recuperás`, `mirás`, `esperás`, `entrás`, `cerrás`.
bool isSpanishTuFuture(String word) {
  final lower = word.toLowerCase();
  if (!lower.endsWith('rás')) return false;
  if (spanishIrregularTuFutureRoots.contains(lower)) return true;
  if (spanishIrregularTuFutureCompounds.contains(lower)) return true;
  // Regular `tú` future = `<infinitive ending in ar/er/ir> + 'ás'`.
  final infinitive = lower.substring(0, lower.length - 2);
  return spanishRegularFutureInfinitives.contains(infinitive);
}

/// Voseo imperatives with a final stressed vowel (e.g. `tené`, `mirá`, `hacé`,
/// `vení`, `decí`, `poné`, `andá`) plus unaccented enclitic voseo imperatives
/// such as `fijate` (standard `tú` is `fíjate`).
const List<String> spanishVoseoImperativeForms = [
  'permití',
  'tocá',
  'escaneá',
  'esperá',
  'elegí',
  'iniciá',
  'creá',
  'ingresá',
  'revisá',
  'probá',
  'mirá',
  'andá',
  'poné',
  'tené',
  'hacé',
  'vení',
  'decí',
  'salí',
  'fijate',
  'usá',
  'pegá',
  'activá',
  'desactivá',
  'guardá',
  'vinculá',
  'seleccioná',
  'comenzá',
  'continuá',
  'cambiá',
  'eliminá',
  'cerrá',
  'abrí',
  'subí',
  'seguí',
  'pedí',
  'volvé',
  'traé',
  'dejá',
  'sacá',
  'buscá',
  'verificá',
  'confirmá',
  'cancelá',
  'aceptá',
  'enviá',
  'registrá',
  'conectá',
  'actualizá',
  'descargá',
  'instalá',
  'volá',
  'quedate',
  'acordate',
  'ponete',
  'decime',
  'haceme',
  'venite',
];

/// Present indicative voseo: Rioplatense `-ás`/`-és`/`-ís` (`podés`, `tenés`,
/// `querés`, `sabés`, `hacés`, `decís`, `venís`, `volás`, …) and Chilean `-ís`
/// (`podís`, `tenís`, `querís`, `sabís`, …).
final RegExp spanishVoseoPresent = RegExp(
  r'(?<![\p{L}])[\p{L}]+(?:ás|és|ís)(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

/// Standalone voseo pronoun `vos`.
final RegExp spanishVoseoPronoun = RegExp(
  r'(?<![\p{L}])vos(?![\p{L}])',
  caseSensitive: false,
  unicode: true,
);

/// Conservative list of common imperative/polite usted verbs in Spanish UI copy.
const List<String> spanishUstedImperativeForms = [
  'use',
  'escanee',
  'inicie',
  'pegue',
  'elija',
  'seleccione',
  'revise',
  'conceda',
  'excluya',
  'desactive',
  'active',
  'vincule',
  'vincúlelo',
  'vincúlela',
  'inténtelo',
  'ingrese',
  'comience',
  'haga',
  'regístrese',
  'presione',
  'toque',
];

/// Possessive and pronoun usted forms (standalone words so e.g. "pídele" is allowed).
final RegExp spanishUstedPronouns = RegExp(
  r'\b(?:usted|ustedes|su|sus|le)\b',
  caseSensitive: false,
  unicode: true,
);

/// Sentence-initial or negated modal usted verbs ("Debe activar", "Puede cambiar", "No puede").
final RegExp spanishUstedModals = RegExp(
  r'(?:^|[.,;:!?]\s+|\bno\s+)(?:puede|debe)\b',
  caseSensitive: false,
  unicode: true,
);

/// Forbidden anglicisms in Spanish UI values (passkey is intentionally allowed).
final RegExp spanishAnglicisms = RegExp(
  r'\b(?:check-?in|tracking|tokens?)\b',
  caseSensitive: false,
  unicode: true,
);

bool _hasWholeWord(String text, String word) {
  final pattern = '(?:^|[^\\p{L}])${RegExp.escape(word)}(?:\$|[^\\p{L}])';
  return RegExp(pattern, unicode: true, caseSensitive: false).hasMatch(text);
}

/// Returns human-readable voseo violation labels found in [text] (empty if clean).
List<String> findSpanishVoseoViolations(String text) {
  final hits = <String>[];

  for (final imperative in spanishVoseoImperativeForms) {
    if (_hasWholeWord(text, imperative)) {
      hits.add('imperative:$imperative');
    }
  }
  for (final m in spanishVoseoPresent.allMatches(text)) {
    final word = m.group(0)!;
    final lower = word.toLowerCase();
    if (spanishVoseoAllowlist.contains(lower)) continue;
    if (isSpanishTuFuture(lower)) continue;
    hits.add('present:$word');
  }
  for (final m in spanishVoseoPronoun.allMatches(text)) {
    hits.add('pronoun:${m.group(0)}');
  }

  return hits;
}

/// Returns human-readable usted-register violation labels found in [text].
List<String> findSpanishUstedViolations(String text) {
  final hits = <String>[];

  for (final verb in spanishUstedImperativeForms) {
    if (_hasWholeWord(text, verb)) {
      hits.add('usted-verb:$verb');
    }
  }
  for (final m in spanishUstedPronouns.allMatches(text)) {
    hits.add('usted-pronoun:${m.group(0)}');
  }
  for (final m in spanishUstedModals.allMatches(text)) {
    final matched = m.group(0)!.trim();
    hits.add('usted-modal:$matched');
  }

  return hits;
}

/// Returns anglicism violations (`check-in`, `tracking`, `token`) found in [text].
List<String> findSpanishAnglicismViolations(String text) {
  final hits = <String>[];
  for (final m in spanishAnglicisms.allMatches(text)) {
    hits.add('anglicism:${m.group(0)}');
  }
  return hits;
}

/// Returns all es-CL Spanish copy violations (voseo + usted + forbidden anglicisms).
List<String> findSpanishCopyViolations(String text) => [
      ...findSpanishVoseoViolations(text),
      ...findSpanishUstedViolations(text),
      ...findSpanishAnglicismViolations(text),
    ];

bool spanishCopyIsVoseoFree(String text) => findSpanishVoseoViolations(text).isEmpty;
