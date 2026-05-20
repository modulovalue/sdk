import 'sampling.dart';
import 'score_emitter.dart';

const int minimumMeasureDurationMillis = 2000;

class BenchmarkBase {
  final String name;
  final ScoreEmitter emitter;

  const BenchmarkBase(this.name, {this.emitter = const PrintEmitter()});

  void run() {}

  void warmup() {
    run();
  }

  void exercise() {
    for (var i = 0; i < 10; i++) {
      run();
    }
  }

  void setup() {}
  void teardown() {}

  static double measureFor(void Function() f, int minimumMillis) {
    final minimumMicros = minimumMillis * 1000;
    final watch = Stopwatch()..start();
    var iter = 0;
    var elapsed = 0;
    while (elapsed < minimumMicros) {
      f();
      elapsed = watch.elapsedMicroseconds;
      iter++;
    }
    return elapsed / iter;
  }

  double measure() {
    if (captureMode) {
      return runSyncSampling(
        name: name,
        setup: setup,
        benchRun: run,
        teardown: teardown,
      );
    }
    setup();
    measureFor(warmup, 100);
    final r =
        measureFor(exercise, minimumMeasureDurationMillis) / 10;
    teardown();
    return r;
  }

  void report() {
    emitter.emit(name, measure());
  }
}
