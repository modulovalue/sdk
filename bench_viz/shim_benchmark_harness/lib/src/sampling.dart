// Shared sampling logic + JSONL writer. Used by both BenchmarkBase and
// AsyncBenchmarkBase shims.

import 'dart:convert';
import 'dart:io';

class _Config {
  final String? outPath;
  final int seconds;
  final int targetBatchMicros;
  final int warmupMillis;

  _Config()
      : outPath = Platform.environment['BENCH_VIZ_OUT'],
        seconds = int.tryParse(
                Platform.environment['BENCH_VIZ_SECONDS'] ?? '') ??
            1,
        targetBatchMicros = int.tryParse(
                Platform.environment['BENCH_VIZ_TARGET_BATCH_US'] ?? '') ??
            1000,
        warmupMillis = int.tryParse(
                Platform.environment['BENCH_VIZ_WARMUP_MS'] ?? '') ??
            200;
}

final _config = _Config();

bool get captureMode => _config.outPath != null;

/// Sync sampling. Returns the median microseconds-per-op (so reports() that
/// previously printed a number still print something sensible).
double runSyncSampling({
  required String name,
  required void Function() setup,
  required void Function() benchRun,
  required void Function() teardown,
}) {
  setup();
  try {
    final iters = _calibrateSync(benchRun);
    _warmupSync(benchRun, iters);
    final samples = <int>[];
    final deadline = DateTime.now().add(Duration(seconds: _config.seconds));
    final sw = Stopwatch();
    while (DateTime.now().isBefore(deadline)) {
      sw.reset();
      sw.start();
      for (var i = 0; i < iters; i++) {
        benchRun();
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    _emit(name, iters, samples);
    return _median(samples) / iters;
  } finally {
    teardown();
  }
}

/// Async variant.
Future<double> runAsyncSampling({
  required String name,
  required Future<void> Function() setup,
  required Future<void> Function() benchRun,
  required Future<void> Function() teardown,
}) async {
  await setup();
  try {
    final iters = await _calibrateAsync(benchRun);
    await _warmupAsync(benchRun, iters);
    final samples = <int>[];
    final deadline = DateTime.now().add(Duration(seconds: _config.seconds));
    final sw = Stopwatch();
    while (DateTime.now().isBefore(deadline)) {
      sw.reset();
      sw.start();
      for (var i = 0; i < iters; i++) {
        await benchRun();
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    _emit(name, iters, samples);
    return _median(samples) / iters;
  } finally {
    await teardown();
  }
}

int _calibrateSync(void Function() f) {
  var n = 1;
  while (n <= 1 << 24) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      f();
    }
    sw.stop();
    if (sw.elapsedMicroseconds >= _config.targetBatchMicros) return n;
    final elapsed = sw.elapsedMicroseconds.clamp(1, 1 << 30);
    final scale = (_config.targetBatchMicros / elapsed).ceil().clamp(2, 8);
    n *= scale;
  }
  return n;
}

Future<int> _calibrateAsync(Future<void> Function() f) async {
  var n = 1;
  while (n <= 1 << 20) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await f();
    }
    sw.stop();
    if (sw.elapsedMicroseconds >= _config.targetBatchMicros) return n;
    final elapsed = sw.elapsedMicroseconds.clamp(1, 1 << 30);
    final scale = (_config.targetBatchMicros / elapsed).ceil().clamp(2, 8);
    n *= scale;
  }
  return n;
}

void _warmupSync(void Function() f, int iters) {
  final deadline =
      DateTime.now().add(Duration(milliseconds: _config.warmupMillis));
  while (DateTime.now().isBefore(deadline)) {
    for (var i = 0; i < iters; i++) {
      f();
    }
  }
}

Future<void> _warmupAsync(Future<void> Function() f, int iters) async {
  final deadline =
      DateTime.now().add(Duration(milliseconds: _config.warmupMillis));
  while (DateTime.now().isBefore(deadline)) {
    for (var i = 0; i < iters; i++) {
      await f();
    }
  }
}

double _median(List<int> samples) {
  if (samples.isEmpty) return 0;
  final s = [...samples]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2].toDouble() : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

void _emit(String name, int iters, List<int> samples) {
  if (!captureMode) return;
  final record = {
    'name': name,
    'iterationsPerSample': iters,
    'durationSeconds': _config.seconds.toDouble(),
    'samples': [
      for (var i = 0; i < samples.length; i++)
        {'i': i, 'us': samples[i], 'iters': iters},
    ],
  };
  // Append one JSONL line per report() call.
  final f = File(_config.outPath!);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('${jsonEncode(record)}\n',
      mode: FileMode.writeOnlyAppend);
}
