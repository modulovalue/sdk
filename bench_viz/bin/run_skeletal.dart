// Runs the SkeletalAnimation benchmark through the sampling harness and
// dumps per-sample timings to JSON.
//
// Usage:
//   dart bin/run_skeletal.dart [--out path/to/file.json] [--seconds N]

import 'dart:io';
import 'dart:typed_data';

import 'package:bench_viz/sampling_harness.dart';
import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:vector_math/vector_math_operations.dart';

class SkeletalAnimation extends BenchmarkBase {
  SkeletalAnimation() : super('SkeletalAnimation');

  final Float32List A = Float32List(16);
  final Float32List B = Float32List(16);
  final Float32List C = Float32List(16);
  final Float32List D = Float32List(4);
  final Float32List E = Float32List(4);

  @override
  void run() {
    for (int i = 0; i < 100; i++) {
      Matrix44Operations.multiply(C, 0, A, 0, B, 0);
      Matrix44Operations.transform4(E, 0, A, 0, D, 0);
    }
  }
}

void main(List<String> args) async {
  var outPath = 'out/skeletal.json';
  var seconds = 2;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--out' && i + 1 < args.length) {
      outPath = args[++i];
    } else if (a == '--seconds' && i + 1 < args.length) {
      seconds = int.parse(args[++i]);
    }
  }

  final harness = SamplingHarness(
    SkeletalAnimation(),
    duration: Duration(seconds: seconds),
  );
  stdout.writeln('Running ${harness.benchmark.name} for ${seconds}s...');
  harness.run();
  stdout.writeln('Captured ${harness.samples.length} samples '
      '(iterationsPerSample=${harness.iterationsPerSample}).');

  final f = await harness.writeJson(outPath);
  stdout.writeln('Wrote ${f.path}.');
}
