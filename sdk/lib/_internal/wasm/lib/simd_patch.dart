// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:_internal' show patch;
import 'dart:_simd';

// These are naive patches for SIMD typed data which we can use until Wasm
// we implement intrinsics for Wasm SIMD.
// TODO(joshualitt): Implement SIMD intrinsics and delete this patch.

@patch
class Int32x4 {
  @patch
  factory Int32x4(int x, int y, int z, int w) = NaiveInt32x4;

  @patch
  factory Int32x4.bool(bool x, bool y, bool z, bool w) = NaiveInt32x4.bool;

  @patch
  factory Int32x4.fromFloat32x4Bits(Float32x4 x) =
      NaiveInt32x4.fromFloat32x4Bits;
}

@patch
class Float32x4 {
  @patch
  factory Float32x4(double x, double y, double z, double w) = NaiveFloat32x4;

  @patch
  factory Float32x4.splat(double value) = NaiveFloat32x4.splat;

  @patch
  factory Float32x4.zero() = NaiveFloat32x4.zero;

  @patch
  factory Float32x4.fromInt32x4Bits(Int32x4 bits) =
      NaiveFloat32x4.fromInt32x4Bits;

  @patch
  factory Float32x4.fromFloat64x2(Float64x2 xy) = NaiveFloat32x4.fromFloat64x2;
}

@patch
class Float64x2 {
  // The unnamed factory, splat, and zero are `const` in dart:typed_data and
  // redirect to `_Float64x2._/.splat/.zero` defined below.
  @patch
  factory Float64x2.fromFloat32x4(Float32x4 v) = NaiveFloat64x2.fromFloat32x4;
}

/// dart2wasm's redirect target for `const factory Float64x2(...) = _Float64x2._;`.
/// Inherits the entire pure-Dart implementation from `_Float64x2Naive` (in
/// `dart:typed_data`); this stub exists only so the public class's redirect
/// target name resolves on this backend.
final class _Float64x2 extends _Float64x2Naive {
  const _Float64x2._(double x, double y) : super._(x, y);
  const _Float64x2.splat(double v) : super.splat(v);
  const _Float64x2.zero() : super.zero();
}
