/// Detects Argentine voseo patterns in Spanish UI copy (neutral tú expected).
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

bool _hasWholeWord(String text, String word) {
  final pattern = '(?:^|[^\\p{L}])${RegExp.escape(word)}(?:\$|[^\\p{L}])';
  return RegExp(pattern, unicode: true, caseSensitive: false).hasMatch(text);
}

/// Returns human-readable violation labels found in [text] (empty if clean).
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

bool spanishCopyIsVoseoFree(String text) => findSpanishVoseoViolations(text).isEmpty;