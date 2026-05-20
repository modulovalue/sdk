// Reads every <stem>.jsonl in --in-dir and emits one JSON file per record
// into --out-dir, named after the record's `name` field.

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  var inDir = 'out_sub';
  var outDir = 'out';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--in-dir' && i + 1 < args.length) inDir = args[++i];
    if (a == '--out-dir' && i + 1 < args.length) outDir = args[++i];
  }

  Directory(outDir).createSync(recursive: true);
  var emitted = 0;
  for (final f in Directory(inDir).listSync().whereType<File>()) {
    if (!f.path.endsWith('.jsonl')) continue;
    final lines = const LineSplitter().convert(f.readAsStringSync());
    for (final line in lines) {
      if (line.isEmpty) continue;
      final j = jsonDecode(line) as Map<String, dynamic>;
      final name = j['name'] as String;
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      File('$outDir/$safe.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(j),
      );
      emitted++;
    }
  }
  stdout.writeln('Wrote $emitted JSON files to $outDir/.');
}
