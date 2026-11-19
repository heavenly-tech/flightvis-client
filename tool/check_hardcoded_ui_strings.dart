import 'dart:io';

/// Fails when likely user-visible string literals remain outside l10n in pilot UI dirs.
void main() {
  const roots = ['lib/screens', 'lib/widgets'];
  final patterns = <RegExp>[
    RegExp(r'''Text\(\s*['"][^'"\$]+['"]'''),
    RegExp(r'''SnackBar\(\s*content:\s*Text\(\s*['"]'''),
    RegExp(r'''labelText:\s*['"][^'"\$]+['"]'''),
    RegExp(r'''title:\s*const\s+Text\(\s*['"]'''),
    RegExp(r'''label:\s*const\s+Text\(\s*['"]'''),
    RegExp(r'''child:\s*const\s+Text\(\s*['"]'''),
    RegExp(r"""setState\(\(\)\s*=>\s*_\w+\s*=\s*'[^']+'\s*\)"""),
  ];
  const allowFiles = <String>{};
  const allowSubstrings = ['//', 'Icons.', 'Key(', 'flight-demo', 'N12345'];

  var hits = 0;
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (allowFiles.contains(file.path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (allowSubstrings.any(line.contains)) continue;
        for (final re in patterns) {
          if (re.hasMatch(line)) {
            hits++;
            stderr.writeln('${file.path}:${i + 1}: $line');
            break;
          }
        }
      }
    }
  }
  if (hits > 0) {
    stderr.writeln('$hits possible hardcoded UI string(s) — use AppLocalizations.');
    exit(1);
  }
  stdout.writeln('No hardcoded UI string patterns detected in screens/widgets.');
}