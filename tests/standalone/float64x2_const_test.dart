// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

const Float64x2 _one = Float64x2(1.0, 2.0);
const Float64x2 _two = Float64x2(3.0, 4.0);
const Float64x2 _splat = Float64x2.splat(7.0);
const Float64x2 _zero = Float64x2.zero();

void check(bool ok, String label) {
  if (!ok) throw 'FAIL: $label';
}

void main() {
  // Compile-time const construction.
  check(_one.x == 1.0 && _one.y == 2.0, 'unnamed const lanes');
  check(_splat.x == 7.0 && _splat.y == 7.0, 'splat const lanes');
  check(_zero.x == 0.0 && _zero.y == 0.0, 'zero const lanes');

  // Const canonicalization.
  const a = Float64x2(1.5, 2.5);
  const b = Float64x2(1.5, 2.5);
  check(identical(a, b), 'canonical identity');

  // Runtime construction.
  final r1 = Float64x2(0.5, 0.25);
  check(r1.x == 0.5 && r1.y == 0.25, 'runtime unnamed');
  final r2 = Float64x2.splat(3.0);
  check(r2.x == 3.0 && r2.y == 3.0, 'runtime splat');
  final r3 = Float64x2.zero();
  check(r3.x == 0.0 && r3.y == 0.0, 'runtime zero');

  // SIMD operators between const operands.
  final cc = _one + _two;
  check(cc.x == 4.0 && cc.y == 6.0, 'const + const add');
  final cm = _two * _two;
  check(cm.x == 9.0 && cm.y == 16.0, 'const * const mul');

  // Mixed const + runtime SIMD.
  final mix = _one + r1;
  check(mix.x == 1.5 && mix.y == 2.25, 'const + runtime add');

  print('OK');
}
