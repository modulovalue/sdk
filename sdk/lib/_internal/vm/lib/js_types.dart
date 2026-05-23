// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// VM backend implementation of `dart:_js_types`.
///
/// All JS types are extension types over [js.JSValue] (a handle-carrying
/// box). This mirrors the dart2js layout, which uses plain Dart objects;
/// the difference is that our [JSValue] holds an integer handle managed by
/// the embedder's JS-side table rather than a JS object reference held by
/// the host JS runtime directly.
library dart._js_types;

import 'dart:_js_helper' as js;

extension type JSAnyType(js.JSValue _jsAnyType) implements Object {}

extension type JSObjectType(js.JSValue _jsObjectType) implements JSAnyType {}

extension type JSFunctionType(js.JSValue _jsFunctionType)
    implements JSObjectType {}

extension type JSExportedDartFunctionType(
  js.JSValue _jsExportedDartFunctionType)
    implements JSFunctionType {}

extension type JSArrayType(js.JSValue _jsArrayType) implements JSObjectType {}

extension type JSBoxedDartObjectType(js.JSValue _jsBoxedDartObjectType)
    implements JSObjectType {}

extension type JSArrayBufferType(js.JSValue _jsArrayBufferType)
    implements JSObjectType {}

extension type JSDataViewType(js.JSValue _jsDataViewType)
    implements JSObjectType {}

extension type JSTypedArrayType(js.JSValue _jsTypedArrayType)
    implements JSObjectType {}

extension type JSInt8ArrayType(js.JSValue _jsInt8ArrayType)
    implements JSTypedArrayType {}

extension type JSUint8ArrayType(js.JSValue _jsUint8ArrayType)
    implements JSTypedArrayType {}

extension type JSUint8ClampedArrayType(js.JSValue _jsUint8ClampedArrayType)
    implements JSTypedArrayType {}

extension type JSInt16ArrayType(js.JSValue _jsInt16ArrayType)
    implements JSTypedArrayType {}

extension type JSUint16ArrayType(js.JSValue _jsUint16ArrayType)
    implements JSTypedArrayType {}

extension type JSInt32ArrayType(js.JSValue _jsInt32ArrayType)
    implements JSTypedArrayType {}

extension type JSUint32ArrayType(js.JSValue _jsUint32ArrayType)
    implements JSTypedArrayType {}

extension type JSFloat32ArrayType(js.JSValue _jsFloat32ArrayType)
    implements JSTypedArrayType {}

extension type JSFloat64ArrayType(js.JSValue _jsFloat64ArrayType)
    implements JSTypedArrayType {}

extension type JSNumberType(js.JSValue _jsNumberType) implements JSAnyType {}

extension type JSBooleanType(js.JSValue _jsBooleanType)
    implements JSAnyType {}

extension type JSStringType(js.JSValue _jsStringType) implements JSAnyType {}

extension type JSPromiseType(js.JSValue _jsPromiseType)
    implements JSObjectType {}

extension type JSSymbolType(js.JSValue _jsSymbolType) implements JSAnyType {}

extension type JSBigIntType(js.JSValue _jsBigIntType) implements JSAnyType {}

// Not a JS type itself, but lives here for the same reason as the JS shim.
typedef ExternalDartReferenceType<T> = T;

// Plain typedef so `JSVoid` and `void` are interchangeable.
typedef JSVoidType = void;
