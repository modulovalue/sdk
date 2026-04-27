// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Benchmarks for int.trailingZeroBitCount and int.oneBitCount, exercised
// through a small bit-array implementation. Each kernel has a `Fast`
// variant that uses the new getters and a `Slow` baseline that does the
// same work bit-by-bit, so the speedup attributable to the intrinsics is
// visible directly.
//
// `main()` first runs a correctness check that asserts both implementations
// agree across a range of sizes and densities, then reports benchmark
// timings via the standard BenchmarkBase harness.

import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:ffi/ffi.dart';

// 32-bit storage words so the benchmark runs on both native (64-bit int)
// and web (32-bit bitwise) without platform-specific word arithmetic.
const int _wordBits = 32;
const int _wordMask = _wordBits - 1;
const int _wordShift = 5;

class BitArray {
  final Uint32List _words;
  final int length;
  Pointer<Uint32>? _ffiPtr;

  BitArray(this.length)
    : _words = Uint32List((length + _wordBits - 1) >> _wordShift);

  Uint32List get words => _words;

  // Lazy-allocated mirror of `_words` in C-allocated memory, for the
  // FFI-pointer cardinality variants. Released with [freeFfi].
  Pointer<Uint32> get ffiPtr {
    final cached = _ffiPtr;
    if (cached != null) return cached;
    final p = malloc.allocate<Uint32>(_words.length * 4);
    for (var i = 0; i < _words.length; i++) {
      p[i] = _words[i];
    }
    _ffiPtr = p;
    return p;
  }

  void freeFfi() {
    final p = _ffiPtr;
    if (p != null) {
      malloc.free(p);
      _ffiPtr = null;
    }
  }

  void setBit(int i) {
    _words[i >> _wordShift] |= 1 << (i & _wordMask);
  }

  bool getBit(int i) =>
      (_words[i >> _wordShift] & (1 << (i & _wordMask))) != 0;

  // ----- cardinality (popcount across all words) ---------------------------

  // Hardware popcount via the new int.oneBitCount intrinsic.
  int cardinalityIntrinsic() {
    var total = 0;
    for (var i = 0; i < _words.length; i++) {
      total += _words[i].oneBitCount;
    }
    return total;
  }

  // 8-way unrolled intrinsic: lets the compiler interleave loads and
  // popcounts and reduces loop-overhead per word.
  int cardinalityIntrinsicUnrolled() {
    final w = _words;
    final n = w.length;
    final limit = n - (n & 7);
    var total = 0;
    for (var i = 0; i < limit; i += 8) {
      total +=
          w[i].oneBitCount +
          w[i + 1].oneBitCount +
          w[i + 2].oneBitCount +
          w[i + 3].oneBitCount +
          w[i + 4].oneBitCount +
          w[i + 5].oneBitCount +
          w[i + 6].oneBitCount +
          w[i + 7].oneBitCount;
    }
    for (var i = limit; i < n; i++) {
      total += w[i].oneBitCount;
    }
    return total;
  }

  // Same as cardinalityIntrinsic, but reads through a Pointer<Uint32> from
  // dart:ffi instead of a Uint32List. Pointer indexing has no bounds check,
  // so this isolates how much of the Dart-vs-C gap comes from typed-list
  // overhead versus the popcount call itself.
  int cardinalityFfiIntrinsic() {
    final p = ffiPtr;
    final n = _words.length;
    var total = 0;
    for (var i = 0; i < n; i++) {
      total += p[i].oneBitCount;
    }
    return total;
  }

  int cardinalityFfiIntrinsicUnrolled() {
    final p = ffiPtr;
    final n = _words.length;
    final limit = n - (n & 7);
    var total = 0;
    for (var i = 0; i < limit; i += 8) {
      total +=
          p[i].oneBitCount +
          p[i + 1].oneBitCount +
          p[i + 2].oneBitCount +
          p[i + 3].oneBitCount +
          p[i + 4].oneBitCount +
          p[i + 5].oneBitCount +
          p[i + 6].oneBitCount +
          p[i + 7].oneBitCount;
    }
    for (var i = limit; i < n; i++) {
      total += p[i].oneBitCount;
    }
    return total;
  }

  // Hamming weight (SWAR) software popcount, ~12 ops per 32-bit word. The
  // canonical "binary magic numbers" sequence: collapse pairs, then 4-bit
  // groups, then 8-bit groups, then sum bytes via a multiply-and-shift.
  int cardinalitySwar() {
    var total = 0;
    for (var i = 0; i < _words.length; i++) {
      var v = _words[i];
      v = v - ((v >> 1) & 0x55555555);
      v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
      v = (v + (v >> 4)) & 0x0F0F0F0F;
      total += ((v * 0x01010101) >> 24) & 0xFF;
    }
    return total;
  }

  // 8-way unrolled SWAR. Independent dataflow lets the OOO core dispatch
  // the eight SWAR sequences in parallel.
  int cardinalitySwarUnrolled() {
    final w = _words;
    final n = w.length;
    final limit = n - (n & 7);
    var total = 0;
    for (var i = 0; i < limit; i += 8) {
      var a = w[i];
      var b = w[i + 1];
      var c = w[i + 2];
      var d = w[i + 3];
      var e = w[i + 4];
      var f = w[i + 5];
      var g = w[i + 6];
      var h = w[i + 7];
      a = a - ((a >> 1) & 0x55555555);
      b = b - ((b >> 1) & 0x55555555);
      c = c - ((c >> 1) & 0x55555555);
      d = d - ((d >> 1) & 0x55555555);
      e = e - ((e >> 1) & 0x55555555);
      f = f - ((f >> 1) & 0x55555555);
      g = g - ((g >> 1) & 0x55555555);
      h = h - ((h >> 1) & 0x55555555);
      a = (a & 0x33333333) + ((a >> 2) & 0x33333333);
      b = (b & 0x33333333) + ((b >> 2) & 0x33333333);
      c = (c & 0x33333333) + ((c >> 2) & 0x33333333);
      d = (d & 0x33333333) + ((d >> 2) & 0x33333333);
      e = (e & 0x33333333) + ((e >> 2) & 0x33333333);
      f = (f & 0x33333333) + ((f >> 2) & 0x33333333);
      g = (g & 0x33333333) + ((g >> 2) & 0x33333333);
      h = (h & 0x33333333) + ((h >> 2) & 0x33333333);
      a = (a + (a >> 4)) & 0x0F0F0F0F;
      b = (b + (b >> 4)) & 0x0F0F0F0F;
      c = (c + (c >> 4)) & 0x0F0F0F0F;
      d = (d + (d >> 4)) & 0x0F0F0F0F;
      e = (e + (e >> 4)) & 0x0F0F0F0F;
      f = (f + (f >> 4)) & 0x0F0F0F0F;
      g = (g + (g >> 4)) & 0x0F0F0F0F;
      h = (h + (h >> 4)) & 0x0F0F0F0F;
      total +=
          (((a * 0x01010101) >> 24) & 0xFF) +
          (((b * 0x01010101) >> 24) & 0xFF) +
          (((c * 0x01010101) >> 24) & 0xFF) +
          (((d * 0x01010101) >> 24) & 0xFF) +
          (((e * 0x01010101) >> 24) & 0xFF) +
          (((f * 0x01010101) >> 24) & 0xFF) +
          (((g * 0x01010101) >> 24) & 0xFF) +
          (((h * 0x01010101) >> 24) & 0xFF);
    }
    for (var i = limit; i < n; i++) {
      var v = w[i];
      v = v - ((v >> 1) & 0x55555555);
      v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
      v = (v + (v >> 4)) & 0x0F0F0F0F;
      total += ((v * 0x01010101) >> 24) & 0xFF;
    }
    return total;
  }

  // Bit-by-bit baseline.
  int cardinalityNaive() {
    var total = 0;
    for (var i = 0; i < length; i++) {
      if (getBit(i)) total++;
    }
    return total;
  }

  // ----- forEachSetBit (iterate set bits via ctz + clear-lowest) -----------

  void forEachSetBitFast(void Function(int) action) {
    for (var wordIdx = 0; wordIdx < _words.length; wordIdx++) {
      var w = _words[wordIdx];
      final base = wordIdx << _wordShift;
      while (w != 0) {
        final bit = w.trailingZeroBitCount;
        final pos = base + bit;
        if (pos >= length) return;
        action(pos);
        w &= w - 1;
      }
    }
  }

  void forEachSetBitSlow(void Function(int) action) {
    for (var i = 0; i < length; i++) {
      if (getBit(i)) action(i);
    }
  }

  // ----- select(k) (position of the k-th set bit, k >= 0) -----------------

  int selectFast(int k) {
    var remaining = k;
    for (var wordIdx = 0; wordIdx < _words.length; wordIdx++) {
      final w = _words[wordIdx];
      final pop = w.oneBitCount;
      if (remaining < pop) {
        // The k-th set bit lives in this word. Walk the word with ctz.
        var v = w;
        while (remaining > 0) {
          v &= v - 1;
          remaining--;
        }
        return (wordIdx << _wordShift) + v.trailingZeroBitCount;
      }
      remaining -= pop;
    }
    return -1;
  }

  int selectSlow(int k) {
    var seen = 0;
    for (var i = 0; i < length; i++) {
      if (getBit(i)) {
        if (seen == k) return i;
        seen++;
      }
    }
    return -1;
  }

  // ----- totalBitLength (sum of int.bitLength across every word) ----------
  //
  // A synthetic kernel that exercises int.bitLength once per word, the way
  // cardinality exercises int.oneBitCount once per word. Lets us measure
  // bitLength in isolation (and benchmark a future graph-intrinsification
  // of it) without the early-exit behavior of highestSetBit.

  // Hardware path: int.bitLength (asm-intrinsic CLZ today).
  int totalBitLengthIntrinsic() {
    var total = 0;
    for (var i = 0; i < _words.length; i++) {
      total += _words[i].bitLength;
    }
    return total;
  }

  // Software bit-trick equivalent of bitLength on a 32-bit word.
  int totalBitLengthSwar() {
    var total = 0;
    for (var i = 0; i < _words.length; i++) {
      final v = _words[i];
      if (v != 0) total += _highBitInWord(v) + 1;
    }
    return total;
  }

  // ----- highestSetBit (position of the topmost set bit, -1 if empty) -----

  // Hardware path: int.bitLength on the topmost nonzero word. bitLength is
  // currently asm-intrinsified (CLZ on ARM64 / BSR on x64); a candidate for
  // graph-intrinsification.
  int highestSetBitIntrinsic() {
    final w = _words;
    for (var wordIdx = w.length - 1; wordIdx >= 0; wordIdx--) {
      final v = w[wordIdx];
      if (v != 0) {
        final candidate = (wordIdx << _wordShift) + v.bitLength - 1;
        return candidate < length ? candidate : -1;
      }
    }
    return -1;
  }

  // Software bit-trick: log2(v) via binary search. ~5 conditional shifts
  // versus the up-to-32 iterations of the naive scan.
  static int _highBitInWord(int v) {
    var r = 0;
    if (v >= 0x10000) {
      v >>= 16;
      r += 16;
    }
    if (v >= 0x100) {
      v >>= 8;
      r += 8;
    }
    if (v >= 0x10) {
      v >>= 4;
      r += 4;
    }
    if (v >= 0x4) {
      v >>= 2;
      r += 2;
    }
    if (v >= 0x2) {
      r += 1;
    }
    return r;
  }

  int highestSetBitSwar() {
    final w = _words;
    for (var wordIdx = w.length - 1; wordIdx >= 0; wordIdx--) {
      final v = w[wordIdx];
      if (v != 0) {
        final candidate = (wordIdx << _wordShift) + _highBitInWord(v);
        return candidate < length ? candidate : -1;
      }
    }
    return -1;
  }

  // Bit-by-bit baseline: scan from the top one position at a time.
  int highestSetBitNaive() {
    for (var i = length - 1; i >= 0; i--) {
      if (getBit(i)) return i;
    }
    return -1;
  }

  // ----- intersection (out = a AND b, materialized as a new BitArray) -----

  // Word-level AND: one bitwise AND per 32-bit word of storage.
  static void intersectionFast(BitArray a, BitArray b, BitArray out) {
    final wa = a._words;
    final wb = b._words;
    final wo = out._words;
    final n = wa.length < wb.length ? wa.length : wb.length;
    for (var i = 0; i < n; i++) {
      wo[i] = wa[i] & wb[i];
    }
  }

  // SIMD AND: 4 words per vector op via Int32x4. No popcount step here, so
  // the SIMD path has a real shot at winning over the scalar word loop.
  // Tail words below the SIMD multiple use the scalar path.
  static void intersectionSimd(BitArray a, BitArray b, BitArray out) {
    final wa = a._words;
    final wb = b._words;
    final wo = out._words;
    final n = wa.length < wb.length ? wa.length : wb.length;
    final simdWords = n >> 2;
    final va = Int32x4List.view(wa.buffer, wa.offsetInBytes, simdWords);
    final vb = Int32x4List.view(wb.buffer, wb.offsetInBytes, simdWords);
    final vo = Int32x4List.view(wo.buffer, wo.offsetInBytes, simdWords);
    for (var i = 0; i < simdWords; i++) {
      vo[i] = va[i] & vb[i];
    }
    for (var i = simdWords << 2; i < n; i++) {
      wo[i] = wa[i] & wb[i];
    }
  }

  // Bit-by-bit AND: classic baseline.
  static void intersectionSlow(BitArray a, BitArray b, BitArray out) {
    // Reset the output so set-only writes produce the correct result.
    for (var i = 0; i < out._words.length; i++) {
      out._words[i] = 0;
    }
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a.getBit(i) && b.getBit(i)) out.setBit(i);
    }
  }

  bool wordsEqual(BitArray other) {
    if (_words.length != other._words.length) return false;
    for (var i = 0; i < _words.length; i++) {
      if (_words[i] != other._words[i]) return false;
    }
    return true;
  }
}

// ----- Correctness check ----------------------------------------------------

BitArray _randomArray(int size, Random rng, int densityPercent) {
  final bits = BitArray(size);
  for (var i = 0; i < size; i++) {
    if (rng.nextInt(100) < densityPercent) bits.setBit(i);
  }
  return bits;
}

void _assertEq(Object? actual, Object? expected, String label) {
  if (actual != expected) {
    throw StateError('FAIL $label: expected $expected, got $actual');
  }
}

void checkCorrectness() {
  final rng = Random(0xDA27);
  for (final size in const [0, 1, 31, 32, 33, 63, 64, 65, 127, 1000, 50000]) {
    for (final density in const [0, 3, 50, 97, 100]) {
      final bits = _randomArray(size, rng, density);

      _assertEq(
        bits.cardinalityIntrinsic(),
        bits.cardinalityNaive(),
        'cardinality.intrinsic(size=$size, density=$density)',
      );
      _assertEq(
        bits.cardinalityIntrinsicUnrolled(),
        bits.cardinalityNaive(),
        'cardinality.intrinsic.unrolled(size=$size, density=$density)',
      );
      _assertEq(
        bits.cardinalityFfiIntrinsic(),
        bits.cardinalityNaive(),
        'cardinality.ffi.intrinsic(size=$size, density=$density)',
      );
      _assertEq(
        bits.cardinalityFfiIntrinsicUnrolled(),
        bits.cardinalityNaive(),
        'cardinality.ffi.intrinsic.unrolled(size=$size, density=$density)',
      );
      bits.freeFfi();
      _assertEq(
        bits.cardinalitySwar(),
        bits.cardinalityNaive(),
        'cardinality.swar(size=$size, density=$density)',
      );
      _assertEq(
        bits.cardinalitySwarUnrolled(),
        bits.cardinalityNaive(),
        'cardinality.swar.unrolled(size=$size, density=$density)',
      );

      final fastList = <int>[];
      final slowList = <int>[];
      bits.forEachSetBitFast(fastList.add);
      bits.forEachSetBitSlow(slowList.add);
      _assertEq(
        fastList.length,
        slowList.length,
        'forEach count (size=$size, density=$density)',
      );
      for (var i = 0; i < fastList.length; i++) {
        _assertEq(
          fastList[i],
          slowList[i],
          'forEach[$i] (size=$size, density=$density)',
        );
      }

      final cardinality = bits.cardinalityIntrinsic();
      for (final k in [0, 1, cardinality >> 1, cardinality - 1]) {
        if (k < 0 || k >= cardinality) continue;
        _assertEq(
          bits.selectFast(k),
          bits.selectSlow(k),
          'select(size=$size, density=$density, k=$k)',
        );
      }

      _assertEq(
        bits.highestSetBitIntrinsic(),
        bits.highestSetBitNaive(),
        'highestSetBit.intrinsic(size=$size, density=$density)',
      );
      _assertEq(
        bits.highestSetBitSwar(),
        bits.highestSetBitNaive(),
        'highestSetBit.swar(size=$size, density=$density)',
      );
      _assertEq(
        bits.totalBitLengthIntrinsic(),
        bits.totalBitLengthSwar(),
        'totalBitLength(size=$size, density=$density)',
      );

      final other = _randomArray(size, rng, density);
      final outSlow = BitArray(size);
      final outFast = BitArray(size);
      final outSimd = BitArray(size);
      BitArray.intersectionSlow(bits, other, outSlow);
      BitArray.intersectionFast(bits, other, outFast);
      // SIMD variant only valid when word count is a multiple of 4 plus
      // tail; checkCorrectness exercises both regimes via varying sizes.
      BitArray.intersectionSimd(bits, other, outSimd);
      _assertEq(
        outFast.wordsEqual(outSlow),
        true,
        'intersect.fast(size=$size, density=$density)',
      );
      _assertEq(
        outSimd.wordsEqual(outSlow),
        true,
        'intersect.simd(size=$size, density=$density)',
      );
    }
  }
}

// ----- Benchmarks -----------------------------------------------------------

const int _benchSize = 1 << 20; // 1,048,576 bits = 32,768 words.

class _BitArrayBenchmark extends BenchmarkBase {
  final int densityPercent;
  final void Function(BitArray) operation;
  late BitArray bits;

  _BitArrayBenchmark(String name, this.densityPercent, this.operation)
    : super('BitArray.$name');

  @override
  void setup() {
    bits = _randomArray(_benchSize, Random(0xBEEF), densityPercent);
  }

  @override
  void run() {
    operation(bits);
  }
}

class _BitArrayPairBenchmark extends BenchmarkBase {
  final int densityPercent;
  final void Function(BitArray, BitArray, BitArray) operation;
  late BitArray a;
  late BitArray b;
  late BitArray out;

  _BitArrayPairBenchmark(String name, this.densityPercent, this.operation)
    : super('BitArray.$name');

  @override
  void setup() {
    a = _randomArray(_benchSize, Random(0xBEEF), densityPercent);
    b = _randomArray(_benchSize, Random(0xC0DE), densityPercent);
    out = BitArray(_benchSize);
  }

  @override
  void run() {
    operation(a, b, out);
  }
}

List<BenchmarkBase> _benchmarks() {
  // Sinks the optimizer cannot fold away.
  var sink = 0;
  void accumulate(int x) {
    sink ^= x;
  }

  return [
    // Cardinality at a quarter density. Five variants:
    //   - naive:               bit-by-bit scan
    //   - swar:                software Hamming-weight popcount per word
    //   - swar.unrolled:       4-way unrolled SWAR
    //   - intrinsic:           hardware popcount via int.oneBitCount
    //   - intrinsic.unrolled:  4-way unrolled intrinsic
    // _BitArrayBenchmark(
    //   'cardinality.naive',
    //   25,
    //   (bits) => sink ^= bits.cardinalityNaive(),
    // ),
    _BitArrayBenchmark(
      'cardinality.swar',
      25,
      (bits) => sink ^= bits.cardinalitySwar(),
    ),
    _BitArrayBenchmark(
      'cardinality.swar.unrolled',
      25,
      (bits) => sink ^= bits.cardinalitySwarUnrolled(),
    ),
    _BitArrayBenchmark(
      'cardinality.intrinsic',
      25,
      (bits) => sink ^= bits.cardinalityIntrinsic(),
    ),
    _BitArrayBenchmark(
      'cardinality.intrinsic.unrolled',
      25,
      (bits) => sink ^= bits.cardinalityIntrinsicUnrolled(),
    ),
    _BitArrayBenchmark(
      'cardinality.ffi.intrinsic',
      25,
      (bits) => sink ^= bits.cardinalityFfiIntrinsic(),
    ),
    _BitArrayBenchmark(
      'cardinality.ffi.intrinsic.unrolled',
      25,
      (bits) => sink ^= bits.cardinalityFfiIntrinsicUnrolled(),
    ),

    // Full iteration over set bits. Fast path uses trailingZeroBitCount +
    // `w &= w - 1`; slow path walks every position.
    _BitArrayBenchmark(
      'forEachSetBit.fast',
      25,
      (bits) => bits.forEachSetBitFast(accumulate),
    ),
    // _BitArrayBenchmark(
    //   'forEachSetBit.slow',
    //   25,
    //   (bits) => bits.forEachSetBitSlow(accumulate),
    // ),

    // select(k) for k near the middle of a quarter-full array. Fast path
    // skips whole words via cumulative popcount, then walks the target
    // word with ctz; slow path scans bit-by-bit from the start.
    _BitArrayBenchmark(
      'select.fast',
      25,
      (bits) => sink ^= bits.selectFast(_benchSize >> 3),
    ),
    // _BitArrayBenchmark(
    //   'select.slow',
    //   25,
    //   (bits) => sink ^= bits.selectSlow(_benchSize >> 3),
    // ),

    // totalBitLength at quarter density: sum int.bitLength across every
    // word. Mirrors cardinality but for bitLength, so the per-call cost
    // of int.bitLength is isolated.
    _BitArrayBenchmark(
      'totalBitLength.swar',
      25,
      (bits) => sink ^= bits.totalBitLengthSwar(),
    ),
    _BitArrayBenchmark(
      'totalBitLength.intrinsic',
      25,
      (bits) => sink ^= bits.totalBitLengthIntrinsic(),
    ),

    // highestSetBit at sparse density (1%): scan words top-down, return
    // position of topmost set bit. Bench dominated by loop scan, not by
    // bitLength itself.
    _BitArrayBenchmark(
      'highestSetBit.swar',
      1,
      (bits) => sink ^= bits.highestSetBitSwar(),
    ),
    _BitArrayBenchmark(
      'highestSetBit.intrinsic',
      1,
      (bits) => sink ^= bits.highestSetBitIntrinsic(),
    ),

    // Intersection: out = a AND b, written into a pre-allocated output.
    // Three variants:
    //   - slow: bit-by-bit scan with setBit
    //   - fast: word-level scalar AND
    //   - simd: Int32x4 AND, 4 words per vector op
    // _BitArrayPairBenchmark(
    //   'intersection.slow',
    //   25,
    //   BitArray.intersectionSlow,
    // ),
    _BitArrayPairBenchmark(
      'intersection.fast',
      25,
      BitArray.intersectionFast,
    ),
    _BitArrayPairBenchmark(
      'intersection.simd',
      25,
      BitArray.intersectionSimd,
    ),
  ];
}

void main() {
  checkCorrectness();
  for (final benchmark in _benchmarks()) {
    benchmark.report();
  }
}
