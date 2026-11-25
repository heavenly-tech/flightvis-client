/// Detects Argentine voseo, usted register, and forbidden anglicisms in es-CL UI copy.
library;

final Set<String> spanishVoseoAllowlist = {
  'está',
  'más',
  'será',
  'aquí',
  'allí',
  'país',
  'también',
  'después',
  'atrás',
  'quizás',
  'jamás',
  'demás',
  'inglés',
  'francés',
  'interés',
};

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
  'vení',
  'decí',
  'salí',
];

/// Present indicative voseo: podés, tenés, querés, sabés, elegís, …
final RegExp spanishVoseoPresent = RegExp(
  r'\b[\p{L}]+(?:ás|és|ís)\b',
  caseSensitive: false,
  unicode: true,
);

final RegExp spanishVoseoPronoun = RegExp(r'\bvos\b', caseSensitive: false, unicode: true);

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
