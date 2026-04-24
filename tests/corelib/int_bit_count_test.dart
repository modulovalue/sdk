// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Testing int.trailingZeroBitCount and int.oneBitCount.

import "package:expect/expect.dart";

// Detect JS number semantics: on JS, 2^53 and 2^53 + 1 are the same double;
// on native they are distinct int64 values.
const bool isWeb = identical(0x20_0000_0000_0000, 0x20_0000_0000_0000 + 1);

// Platform width for bit operations: 64 on native (VM, dart2wasm), 32 on
// dart2js / DDC.
const int width = isWeb ? 32 : 64;

void checkTrailing(int i, int native, int web) {
  Expect.equals(isWeb ? web : native, i.trailingZeroBitCount,
      '$i.trailingZeroBitCount');
}

void checkOne(int i, int native, int web) {
  Expect.equals(isWeb ? web : native, i.oneBitCount, '$i.oneBitCount');
}

void testTrailingZeroBitCount() {
  // Zero: trailing count equals full platform width.
  checkTrailing(0, 64, 32);

  // Positive values.
  checkTrailing(1, 0, 0);
  checkTrailing(2, 1, 1);
  checkTrailing(3, 0, 0);
  checkTrailing(4, 2, 2);
  checkTrailing(8, 3, 3);
  checkTrailing(0x10, 4, 4);
  checkTrailing(0x8000_0000, 31, 31);
  checkTrailing(0x7fff_ffff, 0, 0);

  // Negative values: two's complement preserves low bits.
  checkTrailing(-1, 0, 0);
  checkTrailing(-2, 1, 1);
  checkTrailing(-4, 2, 2);
  checkTrailing(-1024, 10, 10);
  checkTrailing(-0x4000_0000, 30, 30);
  checkTrailing(-0x8000_0000, 31, 31);

  // 64-bit-only values.
  if (!isWeb) {
    checkTrailing(0x1_0000_0000, 32, -1);
    checkTrailing(0x8000_0000_0000_0000, 63, -1);
  }
}

void testOneBitCount() {
  checkOne(0, 0, 0);
  checkOne(1, 1, 1);
  checkOne(2, 1, 1);
  checkOne(3, 2, 2);
  checkOne(7, 3, 3);
  checkOne(0x55, 4, 4);
  checkOne(0xff, 8, 8);
  checkOne(0xffff_ffff, 32, 32);

  // Negative values: sign-extend to platform width.
  checkOne(-1, 64, 32);
  checkOne(-2, 63, 31);
  checkOne(-3, 63, 31);
  checkOne(~0x55, 60, 28);
  checkOne(-0x5555_5555, 49, 17);
  checkOne(-0x7fff_ffff, 34, 2);
  checkOne(-0x8000_0000, 33, 1);

  // 64-bit-only values. `0x5555_5555 * 0x1_0000_0001` constructs
  // 0x5555_5555_5555_5555 and `~0x8000_0000_0000_0000` constructs
  // 0x7fff_ffff_ffff_ffff without literals that fail on the web.
  if (!isWeb) {
    checkOne(0x1_0000_0000, 1, -1);
    final pattern = 0x5555_5555 * 0x1_0000_0001; // = 0x5555_5555_5555_5555
    checkOne(pattern, 32, -1);
    checkOne(~0x8000_0000_0000_0000, 63, -1);
    checkOne(0x8000_0000_0000_0000, 1, -1);
    // Setting any odd-position bit on the alternating pattern should
    // raise the count from 32 to 33, exercising the 64-bit popcount path
    // across all positions.
    for (int i = 1; i < 64; i += 2) {
      Expect.equals(33, (pattern | (1 << i)).oneBitCount,
          '(pattern | (1<<$i)).oneBitCount');
    }
  }
}

// Exhaustive single-bit coverage across the full platform width.
void testSingleBitCoverage() {
  for (int b = 0; b < width; b++) {
    final n = 1 << b;
    Expect.equals(b, n.trailingZeroBitCount,
        '(1<<$b).trailingZeroBitCount');
    Expect.equals(1, n.oneBitCount, '(1<<$b).oneBitCount');
  }
}

void testIdentities() {
  // n.oneBitCount + (~n).oneBitCount == platform width.
  for (final n in const [0, 1, 2, 7, 42, 0x7fff_ffff, -1, -2, -42]) {
    Expect.equals(width, n.oneBitCount + (~n).oneBitCount,
        '$n.oneBitCount + ~$n.oneBitCount');
  }

  // Cross-check: for any nonzero n, `(n & -n) - 1` is a mask of exactly
  // `trailingZeroBitCount(n)` ones, so counting them recovers that count.
  // Exercises both getters against each other.
  for (final n in const [1, 2, 3, 7, 42, 0x4000_0000, -1, -2, -42]) {
    Expect.equals(((n & -n) - 1).oneBitCount, n.trailingZeroBitCount,
        '(($n & -$n) - 1).oneBitCount == $n.trailingZeroBitCount');
  }
}

void main() {
  testTrailingZeroBitCount();
  testOneBitCount();
  testSingleBitCoverage();
  testIdentities();
}
