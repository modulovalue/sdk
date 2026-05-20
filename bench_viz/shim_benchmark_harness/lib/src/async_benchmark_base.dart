import 'sampling.dart';
import 'score_emitter.dart';

class AsyncBenchmarkBase {
  final String name;
  final ScoreEmitter emitter;

  const AsyncBenchmarkBase(this.name,
      {this.emitter = const PrintEmitter()});

  Future<void> run() async {}

  Future<void> warmup() async {
    await run();
  }

  Future<void> exercise() async {
    await run();
  }

  Future<void> setup() async {}
  Future<void> teardown() async {}

  static Future<double> measureFor(
      Future<void> Function() f, int minimumMillis) async {
    final minimumMicros = minimumMillis * 1000;
    final watch = Stopwatch()..start();
    var iter = 0;
    var elapsed = 0;
    while (elapsed < minimumMicros) {
      await f();
      elapsed = watch.elapsedMicroseconds;
      iter++;
    }
    return elapsed / iter;
  }

  Future<double> measure() async {
    if (captureMode) {
      return await runAsyncSampling(
        name: name,
        setup: setup,
        benchRun: run,
        teardown: teardown,
      );
    }
    await setup();
    try {
      await measureFor(warmup, 100);
      return await measureFor(exercise, 2000);
    } finally {
      await teardown();
    }
  }

  Future<void> report() async {
    emitter.emit(name, await measure());
  }
}
