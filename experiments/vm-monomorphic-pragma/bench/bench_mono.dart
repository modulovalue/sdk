import 'dart:typed_data';

extension type const NodeId(int value) implements int {}

// (1) THE FEATURE: annotated type parameter -> monomorphized by the VM transform.
class MonoBitArray<@pragma('vm:monomorphic') T extends int> {
  final Uint64List _words;
  MonoBitArray(int capacity) : _words = Uint64List((capacity + 63) >> 6);
  void add(T v) { final int i = v; _words[i >> 6] |= 1 << (i & 63); }
  bool contains(T v) { final int i = v; return (_words[i >> 6] & (1 << (i & 63))) != 0; }
}

// (2) BASELINE: identical, generic, NOT annotated.
class GenericBitArray<T extends int> {
  final Uint64List _words;
  GenericBitArray(int capacity) : _words = Uint64List((capacity + 63) >> 6);
  void add(T v) { final int i = v; _words[i >> 6] |= 1 << (i & 63); }
  bool contains(T v) { final int i = v; return (_words[i >> 6] & (1 << (i & 63))) != 0; }
}

// (3) HAND-MONOMORPHIZED int reference.
class HandBitArray {
  final Uint64List _words;
  HandBitArray(int capacity) : _words = Uint64List((capacity + 63) >> 6);
  void add(int i) { _words[i >> 6] |= 1 << (i & 63); }
  bool contains(int i) => (_words[i >> 6] & (1 << (i & 63))) != 0;
}

const int N = 1 << 16;
const int ITERS = 2000;

int benchMono() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = MonoBitArray<NodeId>(N);
    for (var i = 0; i < N; i++) ba.add(NodeId(i));
    for (var i = 0; i < N; i++) if (ba.contains(NodeId(i))) hits++;
  }
  return hits;
}
int benchGeneric() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = GenericBitArray<NodeId>(N);
    for (var i = 0; i < N; i++) ba.add(NodeId(i));
    for (var i = 0; i < N; i++) if (ba.contains(NodeId(i))) hits++;
  }
  return hits;
}
int benchHand() {
  var hits = 0;
  for (var it = 0; it < ITERS; it++) {
    final ba = HandBitArray(N);
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
  print('${label.padRight(20)} ${sw.elapsedMilliseconds} ms  (checksum=$r)');
}

void main(List<String> args) {
  run('mono(@pragma)', benchMono);
  run('generic(baseline)', benchGeneric);
  run('hand-int', benchHand);
}
