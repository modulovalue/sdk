import 'dart:typed_data';

extension type const NodeId(int value) implements int {}

class MonoBA<@pragma('vm:monomorphic') T extends int> {
  final Uint64List _w;
  MonoBA(int cap) : _w = Uint64List((cap + 63) >> 6);
  @pragma('vm:prefer-inline')
  void add(T v) { final int i = v; _w[i >> 6] |= 1 << (i & 63); }
  @pragma('vm:prefer-inline')
  bool contains(T v) { final int i = v; return (_w[i >> 6] & (1 << (i & 63))) != 0; }
}
class GenBA<T extends int> {
  final Uint64List _w;
  GenBA(int cap) : _w = Uint64List((cap + 63) >> 6);
  @pragma('vm:prefer-inline')
  void add(T v) { final int i = v; _w[i >> 6] |= 1 << (i & 63); }
  @pragma('vm:prefer-inline')
  bool contains(T v) { final int i = v; return (_w[i >> 6] & (1 << (i & 63))) != 0; }
}
class HandBA {
  final Uint64List _w;
  HandBA(int cap) : _w = Uint64List((cap + 63) >> 6);
  @pragma('vm:prefer-inline')
  void add(int i) { _w[i >> 6] |= 1 << (i & 63); }
  @pragma('vm:prefer-inline')
  bool contains(int i) => (_w[i >> 6] & (1 << (i & 63))) != 0;
}

const int N = 1 << 16;
const int ITERS = 2000;

// Pre-build the NodeId values ONCE so the extension-type constructor is NOT in
// the hot loop. This isolates the per-call covariant check.
final List<NodeId> ids = List<NodeId>.generate(N, (i) => NodeId(i));

int benchMono() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = MonoBA<NodeId>(N);
    for (var i = 0; i < N; i++) ba.add(ids[i]);
    for (var i = 0; i < N; i++) if (ba.contains(ids[i])) hits++;
  }
  return hits;
}
int benchGen() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = GenBA<NodeId>(N);
    for (var i = 0; i < N; i++) ba.add(ids[i]);
    for (var i = 0; i < N; i++) if (ba.contains(ids[i])) hits++;
  }
  return hits;
}
int benchHand() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = HandBA(N);
    for (var i = 0; i < N; i++) ba.add(i);
    for (var i = 0; i < N; i++) if (ba.contains(i)) hits++;
  }
  return hits;
}

void run(String label, int Function() f) {
  for (var i = 0; i < 3; i++) f();
  final sw = Stopwatch()..start();
  final r = f();
  sw.stop();
  print('${label.padRight(18)} ${sw.elapsedMilliseconds} ms (checksum=$r)');
}
void main() {
  run('mono(@pragma)', benchMono);
  run('generic', benchGen);
  run('hand-int', benchHand);
}
