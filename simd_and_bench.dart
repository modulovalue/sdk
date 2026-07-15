import 'dart:typed_data';

int runAnd(Int32x4List a, Int32x4List b, Int32x4List o, int iters) {
  for (var it = 0; it < iters; it++) {
    for (var i = 0; i < a.length; i++) {
      o[i] = a[i] & b[i];
    }
  }
  var acc = 0;
  for (var i = 0; i < o.length; i++) acc ^= o[i].x ^ o[i].w;
  return acc;
}

void main() {
  const n = 1024;
  final a = Int32x4List(n), b = Int32x4List(n), o = Int32x4List(n);
  for (var i = 0; i < n; i++) {
    a[i] = Int32x4(i, i * 2, i * 3, i * 4);
    b[i] = Int32x4(i + 7, i | 3, i ^ 5, i & 9);
  }
  runAnd(a, b, o, 2000); // warmup -> trigger JIT optimization
  final sw = Stopwatch()..start();
  final acc = runAnd(a, b, o, 8000);
  sw.stop();
  print('Int32x4 & : ${sw.elapsedMicroseconds} us  (checksum=$acc)');
}
