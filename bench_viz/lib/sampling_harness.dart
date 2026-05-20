import 'dart:convert';
import 'dart:io';

import 'package:benchmark_harness/benchmark_harness.dart';

/// Per-sample timing record. [meanMicrosPerOp] is the wall time of one batch
/// of [iterationsPerSample] back-to-back `run()` calls divided by the batch
/// size, in microseconds. We record per-sample means rather than per-call
/// times because most benchmark `run()` bodies finish faster than the OS
/// stopwatch resolution (~1us on macOS).
class Sample {
  final int batchIndex;
  final double batchElapsedMicros;
  final int iterationsPerSample;

  const Sample(
    this.batchIndex,
    this.batchElapsedMicros,
    this.iterationsPerSample,
  );

  double get meanMicrosPerOp => batchElapsedMicros / iterationsPerSample;

  Map<String, dynamic> toJson() => {
        'i': batchIndex,
        'us': batchElapsedMicros,
        'iters': iterationsPerSample,
      };
}

/// Wraps a `BenchmarkBase` so we keep every batch timing instead of only the
/// minimum across 10 measure() calls (which is what `report()` reports).
///
/// Algorithm:
///   1. setup()
///   2. Calibrate: find a batch size such that one batch ~ [targetBatchMicros].
///   3. Warmup for [warmup].
///   4. For [duration], time each batch and store its elapsed micros.
///   5. teardown().
class SamplingHarness {
  final BenchmarkBase benchmark;
  final Duration warmup;
  final Duration duration;
  final int targetBatchMicros;

  final List<Sample> samples = [];
  late int iterationsPerSample;

  SamplingHarness(
    this.benchmark, {
    this.warmup = const Duration(milliseconds: 200),
    this.duration = const Duration(seconds: 2),
    this.targetBatchMicros = 1000, // 1 ms per batch
  });

  void run() {
    benchmark.setup();
    try {
      iterationsPerSample = _calibrate();
      _warmup();
      _collect();
    } finally {
      benchmark.teardown();
    }
  }

  int _calibrate() {
    var n = 1;
    while (n <= 1 << 24) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        benchmark.run();
      }
      sw.stop();
      if (sw.elapsedMicroseconds >= targetBatchMicros) return n;
      // Scale n proportionally toward the target instead of doubling blindly.
      final elapsed = sw.elapsedMicroseconds.clamp(1, 1 << 30);
      final scale = (targetBatchMicros / elapsed).ceil().clamp(2, 8);
      n *= scale;
    }
    return n;
  }

  void _warmup() {
    final deadline = DateTime.now().add(warmup);
    while (DateTime.now().isBefore(deadline)) {
      for (var i = 0; i < iterationsPerSample; i++) {
        benchmark.run();
      }
    }
  }

  void _collect() {
    final deadline = DateTime.now().add(duration);
    final sw = Stopwatch();
    var idx = 0;
    while (DateTime.now().isBefore(deadline)) {
      sw.reset();
      sw.start();
      for (var i = 0; i < iterationsPerSample; i++) {
        benchmark.run();
      }
      sw.stop();
      samples.add(Sample(idx++, sw.elapsedMicroseconds.toDouble(),
          iterationsPerSample));
    }
  }

  Map<String, dynamic> toJson() => {
        'name': benchmark.name,
        'iterationsPerSample': iterationsPerSample,
        'durationSeconds': duration.inMilliseconds / 1000.0,
        'samples': samples.map((s) => s.toJson()).toList(),
      };

  Future<File> writeJson(String path) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    return f;
  }
}
