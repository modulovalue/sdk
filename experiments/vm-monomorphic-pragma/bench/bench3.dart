import 'dart:typed_data';

class MonoBA<@pragma('vm:monomorphic') T extends int> {
  final Uint64List _w;
  MonoBA(int cap) : _w = Uint64List((cap + 63) >> 6);
  @pragma('vm:never-inline')
  void add(T v) { final int i = v; _w[i >> 6] |= 1 << (i & 63); }
}
class GenBA<T extends int> {
  final Uint64List _w;
  GenBA(int cap) : _w = Uint64List((cap + 63) >> 6);
  @pragma('vm:never-inline')
  void add(T v) { final int i = v; _w[i >> 6] |= 1 << (i & 63); }
}

const int N = 1 << 16;
const int ITERS = 4000;

int benchMono() {
  var s = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = MonoBA<int>(N);
    for (var i = 0; i < N; i++) ba.add(i);   // plain int loop var: only the check differs
    s += it;
  }
  return s;
}
int benchGen() {
  var s = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = GenBA<int>(N);
    for (var i = 0; i < N; i++) ba.add(i);
    s += it;
  }
  return s;
}
void run(String label, int Function() f) {
  for (var i = 0; i < 3; i++) f();
  final sw = Stopwatch()..start();
  final r = f();
  sw.stop();
  print('${label.padRight(18)} ${sw.elapsedMilliseconds} ms (s=$r)');
}
void main() {
  run('mono(@pragma)', benchMono);
  run('generic', benchGen);
  run('mono(@pragma)', benchMono);
  run('generic', benchGen);
}
