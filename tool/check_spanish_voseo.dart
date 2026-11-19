import 'dart:convert';
import 'dart:io';

import 'spanish_voseo.dart';

/// Files and trees scanned for Spanish voseo in pilot UI copy.
const _arbPath = 'lib/l10n/app_es.arb';
const _androidStrings = 'android/app/src/main/res/values/strings.xml';
const _dartUiRoots = ['lib/screens', 'lib/widgets'];

void main() {
  var violations = 0;

  violations += _scanArb(_arbPath);
  violations += _scanXmlStrings(_androidStrings);
  for (final root in _dartUiRoots) {
    violations += _scanDartTree(root);
  }
  violations += _scanReadmeEs();

  if (violations > 0) {
    stderr.writeln('$violations Spanish voseo violation(s) — use neutral tú forms.');
    exit(1);
  }
  stdout.writeln('Spanish copy: no voseo patterns detected.');
}

int _scanArb(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Missing $path');
    return 1;
  }
  final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  var count = 0;
  for (final entry in map.entries) {
    if (entry.key.startsWith('@') || entry.key.startsWith('@@')) continue;
    final value = entry.value;
    if (value is! String) continue;
    final hits = findSpanishVoseoViolations(value);
    if (hits.isNotEmpty) {
      count++;
      stderr.writeln('$path key "${entry.key}": $value');
      stderr.writeln('  → ${hits.join(", ")}');
    }
  }
  return count;
}

int _scanXmlStrings(String path) {
  final file = File(path);
  if (!file.existsSync()) return 0;
  final text = file.readAsStringSync();
  final re = RegExp(r'<string[^>]*>([^<]+)</string>');
  var count = 0;
  for (final m in re.allMatches(text)) {
    final value = m.group(1)!;
    final hits = findSpanishVoseoViolations(value);
    if (hits.isNotEmpty) {
      count++;
      stderr.writeln('$path: $value');
      stderr.writeln('  → ${hits.join(", ")}');
    }
  }
  return count;
}

int _scanDartTree(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return 0;
  var count = 0;
  for (final file in dir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final content = file.readAsStringSync();
    for (final m in RegExp(r'''(?:'|")([^\n'"\\]{3,200})(?:'|")''').allMatches(content)) {
      final literal = m.group(1)!;
      if (!RegExp(r'[áéíóúñÁÉÍÓÚÑ]').hasMatch(literal)) continue;
      final hits = findSpanishVoseoViolations(literal);
      if (hits.isEmpty) continue;
      count++;
      stderr.writeln('${file.path}: "$literal"');
      stderr.writeln('  → ${hits.join(", ")}');
    }
  }
  return count;
}

int _scanReadmeEs() {
  final readme = File('README.md');
  if (!readme.existsSync()) return 0;
  final hits = findSpanishVoseoViolations(readme.readAsStringSync());
  if (hits.isEmpty) return 0;
  stderr.writeln('README.md: ${hits.join(", ")}');
  return 1;
}