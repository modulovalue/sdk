// Spawns each benchmarks/*/dart/*.dart file as a separate `dart` process
// with the shimmed package:benchmark_harness. The shim writes one JSONL
// record per BenchmarkBase.report() call to $BENCH_VIZ_OUT.
//
// Usage:
//   dart bin/run_subprocess.dart [--seconds 1] [--out-dir out_sub]
//                                [--timeout 30] [--include foo,bar]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _benchmarksDir = '../benchmarks';

void main(List<String> args) async {
  var seconds = 1;
  var outDir = 'out_sub';
  var timeoutSec = 30;
  Set<String>? include;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--seconds' && i + 1 < args.length) {
      seconds = int.parse(args[++i]);
    } else if (a == '--out-dir' && i + 1 < args.length) {
      outDir = args[++i];
    } else if (a == '--timeout' && i + 1 < args.length) {
      timeoutSec = int.parse(args[++i]);
    } else if (a == '--include' && i + 1 < args.length) {
      include = args[++i].split(',').toSet();
    }
  }

  final files = _discover();
  Directory(outDir).createSync(recursive: true);
  final logFile = File('$outDir/_orchestrator.log');
  logFile.writeAsStringSync('');

  final summary = <String, _Result>{};
  for (final file in files) {
    final dir = file.path.split('/').reversed.skip(2).first; // e.g. SkeletalAnimation
    if (include != null && !include.contains(dir)) continue;
    final stem = dir;
    final jsonlPath = '${Directory.current.path}/$outDir/$stem.jsonl';
    File(jsonlPath).writeAsStringSync(''); // truncate

    final sw = Stopwatch()..start();
    stdout.write('${stem.padRight(34)} ');
    final result = await _runOne(
      file: file.path,
      jsonlPath: jsonlPath,
      seconds: seconds,
      timeoutSec: timeoutSec,
    );
    sw.stop();

    final lines = File(jsonlPath).existsSync()
        ? const LineSplitter()
            .convert(File(jsonlPath).readAsStringSync())
            .where((l) => l.isNotEmpty)
            .length
        : 0;
    stdout.writeln(
        '${result.label.padRight(10)}  ${lines.toString().padLeft(3)} bench(es)  '
        '${sw.elapsedMilliseconds}ms');
    summary[stem] = _Result(result.label, lines, result.stderr);
    logFile.writeAsStringSync(
      '\n=== $stem === (${result.label}, ${lines} bench, '
          '${sw.elapsedMilliseconds}ms)\n${result.stderr}\n',
      mode: FileMode.append,
    );
  }

  // Write a top-level summary.
  await File('$outDir/_summary.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      for (final e in summary.entries)
        e.key: {
          'status': e.value.label,
          'bench_count': e.value.benchCount,
        },
    }),
  );

  final ok = summary.values.where((r) => r.label == 'OK').length;
  final empty = summary.values.where((r) => r.label == 'NO_OUTPUT').length;
  final failed = summary.values.where((r) =>
      r.label == 'TIMEOUT' || r.label == 'CRASH' || r.label == 'COMPILE_FAIL'
  ).length;
  final totalBench = summary.values.fold<int>(0, (a, r) => a + r.benchCount);
  stdout.writeln('\n=== ${summary.length} files attempted ===');
  stdout.writeln('  OK         : $ok files / $totalBench benchmark records');
  stdout.writeln('  NO_OUTPUT  : $empty files');
  stdout.writeln('  FAILED     : $failed files');
  stdout.writeln('Detail in $outDir/_orchestrator.log');
}

class _Result {
  final String label;
  final int benchCount;
  final String stderr;
  _Result(this.label, this.benchCount, [this.stderr = '']);
}

class _RunResult {
  final String label; // OK | NO_OUTPUT | TIMEOUT | CRASH | COMPILE_FAIL
  final String stderr;
  _RunResult(this.label, this.stderr);
}

List<File> _discover() {
  final root = Directory(_benchmarksDir);
  final files = <File>[];
  for (final d in root.listSync().whereType<Directory>()) {
    final inner = Directory('${d.path}/dart');
    if (!inner.existsSync()) continue;
    for (final f in inner.listSync().whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (!RegExp(r"^(?:Future<void>\s+)?\s*(?:void\s+)?main\s*\(",
              multiLine: true)
          .hasMatch(src)) {
        // Helper file. Skip.
        continue;
      }
      if (!src.contains('package:benchmark_harness/benchmark_harness.dart')) {
        continue;
      }
      files.add(f);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

Future<_RunResult> _runOne({
  required String file,
  required String jsonlPath,
  required int seconds,
  required int timeoutSec,
}) async {
  final args = <String>[
    '--packages=.dart_tool/package_config.json',
    '--enable-experiment=variance',
    file,
  ];
  final env = <String, String>{
    ...Platform.environment,
    'BENCH_VIZ_OUT': jsonlPath,
    'BENCH_VIZ_SECONDS': '$seconds',
  };

  Process? proc;
  try {
    proc = await Process.start('dart', args, environment: env);
  } catch (e) {
    return _RunResult('CRASH', 'spawn failed: $e');
  }

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final outDone = proc.stdout
      .transform(utf8.decoder)
      .listen(stdoutBuf.write)
      .asFuture<void>();
  final errDone = proc.stderr
      .transform(utf8.decoder)
      .listen(stderrBuf.write)
      .asFuture<void>();

  Timer? timer;
  var timedOut = false;
  timer = Timer(Duration(seconds: timeoutSec), () {
    timedOut = true;
    proc!.kill(ProcessSignal.sigkill);
  });

  final exitCode = await proc.exitCode;
  timer.cancel();
  await outDone;
  await errDone;

  if (timedOut) {
    return _RunResult('TIMEOUT', stderrBuf.toString());
  }
  if (exitCode != 0) {
    final err = stderrBuf.toString();
    if (err.contains("Error: Couldn't resolve") ||
        err.contains("Error: Not found:") ||
        err.contains("Error: Compilation failed")) {
      return _RunResult('COMPILE_FAIL', err);
    }
    return _RunResult('CRASH', err);
  }
  if (!File(jsonlPath).existsSync() ||
      File(jsonlPath).lengthSync() == 0) {
    return _RunResult('NO_OUTPUT', stderrBuf.toString());
  }
  return _RunResult('OK', stderrBuf.toString());
}
