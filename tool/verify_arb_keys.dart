import 'dart:convert';
import 'dart:io';

/// Ensures every secondary ARB contains all message keys from [app_es.arb] (template).
void main() {
  final arbDir = Directory('lib/l10n');
  if (!arbDir.existsSync()) {
    stderr.writeln('Missing lib/l10n');
    exit(1);
  }
  final template = File('${arbDir.path}/app_es.arb');
  if (!template.existsSync()) {
    stderr.writeln('Missing template app_es.arb');
    exit(1);
  }
  final templateKeys = _messageKeys(jsonDecode(template.readAsStringSync()) as Map<String, dynamic>);

  var failed = false;
  for (final entity in arbDir.listSync().whereType<File>()) {
    final name = entity.uri.pathSegments.last;
    if (!name.startsWith('app_') || !name.endsWith('.arb') || name == 'app_es.arb') continue;
    final map = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    final keys = _messageKeys(map);
    final missing = templateKeys.difference(keys);
    if (missing.isNotEmpty) {
      failed = true;
      stderr.writeln('$name is missing ${missing.length} key(s) from app_es.arb:');
      for (final k in missing.toList()..sort()) {
        stderr.writeln('  - $k');
      }
    }
  }
  if (failed) exit(1);
  stdout.writeln('ARB key parity OK (${templateKeys.length} template keys).');
}

Set<String> _messageKeys(Map<String, dynamic> arb) {
  return arb.keys.where((k) => !k.startsWith('@') && k != '@@locale').toSet();
}