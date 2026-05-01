// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Benchmark suite for the `const Float64x2(...)` constructor introduced in
// the previous commit. For each of the `add`, `mul`, and `mul-add` broadcast
// patterns, compares the cost of:
//
//   * a plain scalar `Float64List` loop (baseline for context),
//   * a SIMD loop where the broadcast value is allocated once per `run()`,
//   * a SIMD loop that allocates a fresh `Float64x2(...)` every iteration
//     (the worst case the const path is meant to dominate),
//   * a SIMD loop that uses a top-level `const Float64x2(...)`.
//
// The const variant exercises the new const-evaluation path: on the VM the
// constant becomes a pre-allocated `_Float64x2` heap object whose lanes the
// SIMD intrinsics load directly; on dart2js / DDC / dart2wasm it becomes an
// instance of `_Float64x2Naive` materialized at startup.
//
// `mul-add` has no alloc-per-iteration variant; the three-way scalar /
// runtime / const comparison is enough to expose the const path's benefit
// there.

import 'dart:typed_data';

import 'package:benchmark_harness/benchmark_harness.dart';

const int doubles = 4096;
const Float64x2 _kAddend = Float64x2(0.5, -0.25);
const Float64x2 _kScale = Float64x2(2.0, 2.0);

abstract class SimdBench extends BenchmarkBase {
  SimdBench(String name) : super('SimdFloat64x2.$name');

  late final Float64List a;
  late final Float64List b;

  @override
  void setup() {
    a = Float64List(doubles);
    b = Float64List(doubles);
    for (int i = 0; i < doubles; i++) {
      a[i] = (i % 17).toDouble() - 8.0;
      b[i] = ((i * 31) % 13).toDouble() + 0.125;
    }
  }
}

class AddBroadcastScalar extends SimdBench {
  AddBroadcastScalar() : super('addBroadcastScalar');
  @override
  void run() {
    const cx = 0.5;
    const cy = -0.25;
    final n = a.length;
    for (int i = 0; i < n; i += 2) {
      a[i] = a[i] + cx;
      a[i + 1] = a[i + 1] + cy;
    }
  }
}

class AddBroadcastSimdRuntime extends SimdBench {
  AddBroadcastSimdRuntime() : super('addBroadcastSimdRuntime');
  @override
  void run() {
    // Allocated once per run() outside the inner loop. The optimizer is
    // expected to hoist this and produce numbers very close to
    // `addBroadcastSimdConst` on backends with good escape analysis.
    final addend = Float64x2(0.5, -0.25);
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] + addend;
    }
  }
}

/// Worst-case runtime variant: allocates a fresh `Float64x2` every iteration
/// so the optimizer cannot share the broadcast value across the loop. This
/// is the case `addBroadcastSimdConst` is meant to dominate: const broadcast
/// pays zero per-iteration allocation cost regardless of optimizer behaviour.
class AddBroadcastSimdAllocPerIter extends SimdBench {
  AddBroadcastSimdAllocPerIter() : super('addBroadcastSimdAllocPerIter');
  @override
  void run() {
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] + Float64x2(0.5, -0.25);
    }
  }
}

class AddBroadcastSimdConst extends SimdBench {
  AddBroadcastSimdConst() : super('addBroadcastSimdConst');
  @override
  void run() {
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] + _kAddend;
    }
  }
}

class MulBroadcastScalar extends SimdBench {
  MulBroadcastScalar() : super('mulBroadcastScalar');
  @override
  void run() {
    const cx = 2.0;
    const cy = 2.0;
    final n = a.length;
    for (int i = 0; i < n; i += 2) {
      a[i] = a[i] * cx;
      a[i + 1] = a[i + 1] * cy;
    }
  }
}

class MulBroadcastSimdRuntime extends SimdBench {
  MulBroadcastSimdRuntime() : super('mulBroadcastSimdRuntime');
  @override
  void run() {
    final scale = Float64x2(2.0, 2.0);
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] * scale;
    }
  }
}

class MulBroadcastSimdAllocPerIter extends SimdBench {
  MulBroadcastSimdAllocPerIter() : super('mulBroadcastSimdAllocPerIter');
  @override
  void run() {
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] * Float64x2(2.0, 2.0);
    }
  }
}

class MulBroadcastSimdConst extends SimdBench {
  MulBroadcastSimdConst() : super('mulBroadcastSimdConst');
  @override
  void run() {
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] * _kScale;
    }
  }
}

// Compound (`a[i] = a[i] * scale + offset`) broadcast: two ops per element,
// more compute relative to memory traffic.

class MulAddBroadcastScalar extends SimdBench {
  MulAddBroadcastScalar() : super('mulAddBroadcastScalar');
  @override
  void run() {
    const sx = 2.0, sy = 2.0;
    const ox = 0.5, oy = -0.25;
    final n = a.length;
    for (int i = 0; i < n; i += 2) {
      a[i] = a[i] * sx + ox;
      a[i + 1] = a[i + 1] * sy + oy;
    }
  }
}

class MulAddBroadcastSimdRuntime extends SimdBench {
  MulAddBroadcastSimdRuntime() : super('mulAddBroadcastSimdRuntime');
  @override
  void run() {
    final scale = Float64x2(2.0, 2.0);
    final offset = Float64x2(0.5, -0.25);
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] * scale + offset;
    }
  }
}

class MulAddBroadcastSimdConst extends SimdBench {
  MulAddBroadcastSimdConst() : super('mulAddBroadcastSimdConst');
  @override
  void run() {
    final la = Float64x2List.view(a.buffer, a.offsetInBytes, a.length >> 1);
    for (int j = 0; j < la.length; j++) {
      la[j] = la[j] * _kScale + _kAddend;
    }
  }
}

void main() {
  final benchmarks = <BenchmarkBase Function()>[
    AddBroadcastScalar.new,
    AddBroadcastSimdRuntime.new,
    AddBroadcastSimdAllocPerIter.new,
    AddBroadcastSimdConst.new,
    MulBroadcastScalar.new,
    MulBroadcastSimdRuntime.new,
    MulBroadcastSimdAllocPerIter.new,
    MulBroadcastSimdConst.new,
    MulAddBroadcastScalar.new,
    MulAddBroadcastSimdRuntime.new,
    MulAddBroadcastSimdConst.new,
  ];

  // Warm up.
  for (final bm in benchmarks) {
    bm()
      ..setup()
      ..run()
      ..run();
  }

  for (final bm in benchmarks) {
    bm().report();
  }
}
