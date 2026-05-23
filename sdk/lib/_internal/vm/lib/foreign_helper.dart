// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// VM stub for `dart:_foreign_helper`.
///
/// In dart2js this library exposes the compile-time `JS('expr', #, #)`
/// intrinsic. The Dart-Live VM has no equivalent — the JS-interop
/// transformer pipeline (`JsUtilOptimizer`) just *references* the
/// procedure by name to check "is this call already a foreign-helper
/// `JS()` call?". It never *emits* one. So a stub is enough to make
/// the procedure lookup succeed.
library dart._foreign_helper;

/// Stub for dart2js's foreign-helper `JS`. Not callable on the VM.
T JS<T>(String typeDescription, String codeTemplate,
        [Object? a, Object? b, Object? c, Object? d,
         Object? e, Object? f, Object? g, Object? h]) =>
    throw UnsupportedError(
        'dart:_foreign_helper.JS is not implemented on the Dart-Live VM '
        'backend; use dart:js_interop / dart:js_interop_unsafe instead.');
