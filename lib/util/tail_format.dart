/// Chile-style club tail `CC-XXX` (three letters after prefix).
final RegExp chileTailPattern = RegExp(r'^CC-[A-Z]{3}$');

String? validateChileTail(String raw) {
  final tail = raw.trim().toUpperCase();
  if (tail.isEmpty) return null;
  if (!chileTailPattern.hasMatch(tail)) {
    return 'invalid_tail';
  }
  return null;
}

String normalizeChileTail(String raw) => raw.trim().toUpperCase();