// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// VM backend patch for `dart:js_interop`.
///
/// Phase 1: implements the subset needed by `dart:js_interop_unsafe`
/// (`globalContext`, basic primitive conversions, `typeofEquals`,
/// `instanceof`, object-literal construction). Many other members of the
/// public API are left as their original `external` declarations: calling
/// them will fail at runtime with an unresolved-native error, exactly the
/// same way the standard VM would today. That keeps this patch small and
/// the surface area we have to test small; subsequent phases will add
/// patches for the rest.

import 'dart:_internal' show patch;
import 'dart:_js_helper' show JSValue, newObjectRaw, globalThisRaw,
    exportDartFunctionAsJS, promiseToDartFuture;
import 'dart:_js_helper' as _h show JS;
import 'dart:_js_types' as js_types;
import 'dart:async' show Completer, Future;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@patch
js_types.JSObjectType _createObjectLiteral() =>
    js_types.JSObjectType(newObjectRaw());

@patch
JSObject get globalContext =>
    JSObject._(js_types.JSObjectType(JSValue(0)));

@patch
extension NullableUndefineableJSAnyExtension on JSAny? {
  @patch
  bool get isUndefined => this == null
      ? false
      : _h.JS<bool>('bool', 'a[0] === undefined', this);

  @patch
  bool get isNull => this == null
      ? false
      : _h.JS<bool>('bool', 'a[0] === null', this);
}

@patch
extension JSAnyUtilityExtension on JSAny? {
  @patch
  bool typeofEquals(String typeString) =>
      _h.JS<bool>('bool', 'typeof a[0] === a[1]', this, typeString);

  @patch
  bool instanceof(JSFunction constructor) =>
      _h.JS<bool>('bool', 'a[0] instanceof a[1]', this, constructor);

  @patch
  Object? dartify() => _h.JS<dynamic>('', 'a[0]', this);
}

@patch
extension NullableObjectUtilExtension on Object? {
  @patch
  JSAny? jsify() => _h.JS<JSAny?>('', 'a[0]', this);

  @patch
  bool isA<T>() => throw UnimplementedError(
        'isA<T> requires the interop transformer; not available on the VM '
        'backend yet.',
      );
}

// === Primitive promotion / demotion ===

@patch
extension StringToJSString on String {
  @patch
  JSString get toJS => JSString._(js_types.JSStringType(_jsWrap(this)));
}

@patch
extension JSStringToString on JSString {
  @patch
  String get toDart =>
      _h.JS<String>('String', 'String(a[0])', this);
}

@patch
extension BoolToJSBoolean on bool {
  @patch
  JSBoolean get toJS => JSBoolean._(js_types.JSBooleanType(_jsWrap(this)));
}

@patch
extension JSBooleanToBool on JSBoolean {
  @patch
  bool get toDart =>
      _h.JS<bool>('bool', '!!a[0]', this);
}

@patch
extension DoubleToJSNumber on double {
  @patch
  JSNumber get toJS => JSNumber._(js_types.JSNumberType(_jsWrap(this)));
}

@patch
extension JSNumberToNumber on JSNumber {
  @patch
  double get toDartDouble =>
      _h.JS<double>('double', '+a[0]', this);

  @patch
  int get toDartInt =>
      _h.JS<int>('int', 'a[0] | 0', this);
}

/// Wraps a Dart primitive as a JS handle. Implemented natively so we get a
/// stable handle the JS side can dereference even when the value would
/// otherwise just be passed by value.
@pragma("vm:external-name", "Embedder_JS_Wrap")
external JSValue _jsWrap(Object value);

// === Phase 2a: exporting Dart functions to JS ===
//
// `myDartFn.toJS` registers the closure in `dart:_js_helper`'s table and
// returns a JS function handle wrapping that registration. The wrapping is
// done in C++ via `Embedder_JS_MakeCallback`.
//
// `toJSCaptureThis` is the variant where JS's `this` becomes the first
// argument to the Dart closure. Phase 2a doesn't yet preserve `this`;
// users targeting `addEventListener` etc. don't need it.

@patch
extension FunctionToJSExportedDartFunction on Function {
  @patch
  JSExportedDartFunction get toJS => JSExportedDartFunction._(
        js_types.JSExportedDartFunctionType(exportDartFunctionAsJS(this)),
      );

  @patch
  JSExportedDartFunction get toJSCaptureThis => JSExportedDartFunction._(
        js_types.JSExportedDartFunctionType(exportDartFunctionAsJS(this)),
      );
}

// === Phase 2b: JSPromise -> Future via JS-side slot + Dart polling ===
//
// Strategy: build the resolve/reject callbacks as *pure JS functions*
// (constructed at runtime via the `Function` constructor — equivalent to
// `new Function(...)`). They write the resolution state to a slot object.
// Then Dart polls the slot from inside `Future.delayed(Duration.zero)`,
// which yields the wasm task back to the JS event loop (via the embedder
// sleep / Asyncify) and lets JS process the Promise resolution before
// we resume.
//
// The earlier `Function.toJS` Dart-callback path re-entered wasm from a
// JS microtask, which tripped a VM indirect-call corruption on the
// second invocation. This pure-JS-callback variant sidesteps the
// re-entry entirely.

@patch
extension JSPromiseToFuture<T extends JSAny?> on JSPromise<T> {
  @patch
  Future<T> get toDart async =>
      (await promiseToDartFuture(this as JSValue)) as T;
}

// === Phase 5b: typed-data interop ===
//
// Dart Uint8List/Int8List/... <-> JS Uint8Array/Int8Array/... via embedder
// natives that copy bytes between the Dart-side typed-data backing store
// and a fresh JS-side TypedArray of the matching kind.
//
// Kind codes (must match dart_il_extract.cc):
//   0 Uint8   1 Int8   2 Uint8Clamped
//   3 Uint16  4 Int16
//   5 Uint32  6 Int32
//   7 Float32 8 Float64
//   9 ArrayBuffer    10 DataView

@pragma("vm:external-name", "Embedder_TypedData_ToJS")
external JSValue _tdToJS(Object data, int kind);

@pragma("vm:external-name", "Embedder_TypedData_FromJS")
external Object _tdFromJS(int handle, int kind);

@patch
extension Uint8ListToJSUint8Array on Uint8List {
  @patch
  JSUint8Array get toJS =>
      JSUint8Array._(js_types.JSUint8ArrayType(_tdToJS(this, 0)));
}

@patch
extension JSUint8ArrayToUint8List on JSUint8Array {
  @patch
  Uint8List get toDart =>
      _tdFromJS((this as JSValue).handle, 0) as Uint8List;
}

@patch
extension Int8ListToJSInt8Array on Int8List {
  @patch
  JSInt8Array get toJS =>
      JSInt8Array._(js_types.JSInt8ArrayType(_tdToJS(this, 1)));
}

@patch
extension JSInt8ArrayToInt8List on JSInt8Array {
  @patch
  Int8List get toDart =>
      _tdFromJS((this as JSValue).handle, 1) as Int8List;
}

@patch
extension Uint8ClampedListToJSUint8ClampedArray on Uint8ClampedList {
  @patch
  JSUint8ClampedArray get toJS => JSUint8ClampedArray._(
      js_types.JSUint8ClampedArrayType(_tdToJS(this, 2)));
}

@patch
extension JSUint8ClampedArrayToUint8ClampedList on JSUint8ClampedArray {
  @patch
  Uint8ClampedList get toDart =>
      _tdFromJS((this as JSValue).handle, 2) as Uint8ClampedList;
}

@patch
extension Uint16ListToJSUint16Array on Uint16List {
  @patch
  JSUint16Array get toJS =>
      JSUint16Array._(js_types.JSUint16ArrayType(_tdToJS(this, 3)));
}

@patch
extension JSUint16ArrayToUint16List on JSUint16Array {
  @patch
  Uint16List get toDart =>
      _tdFromJS((this as JSValue).handle, 3) as Uint16List;
}

@patch
extension Int16ListToJSInt16Array on Int16List {
  @patch
  JSInt16Array get toJS =>
      JSInt16Array._(js_types.JSInt16ArrayType(_tdToJS(this, 4)));
}

@patch
extension JSInt16ArrayToInt16List on JSInt16Array {
  @patch
  Int16List get toDart =>
      _tdFromJS((this as JSValue).handle, 4) as Int16List;
}

@patch
extension Uint32ListToJSUint32Array on Uint32List {
  @patch
  JSUint32Array get toJS =>
      JSUint32Array._(js_types.JSUint32ArrayType(_tdToJS(this, 5)));
}

@patch
extension JSUint32ArrayToUint32List on JSUint32Array {
  @patch
  Uint32List get toDart =>
      _tdFromJS((this as JSValue).handle, 5) as Uint32List;
}

@patch
extension Int32ListToJSInt32Array on Int32List {
  @patch
  JSInt32Array get toJS =>
      JSInt32Array._(js_types.JSInt32ArrayType(_tdToJS(this, 6)));
}

@patch
extension JSInt32ArrayToInt32List on JSInt32Array {
  @patch
  Int32List get toDart =>
      _tdFromJS((this as JSValue).handle, 6) as Int32List;
}

@patch
extension Float32ListToJSFloat32Array on Float32List {
  @patch
  JSFloat32Array get toJS =>
      JSFloat32Array._(js_types.JSFloat32ArrayType(_tdToJS(this, 7)));
}

@patch
extension JSFloat32ArrayToFloat32List on JSFloat32Array {
  @patch
  Float32List get toDart =>
      _tdFromJS((this as JSValue).handle, 7) as Float32List;
}

@patch
extension Float64ListToJSFloat64Array on Float64List {
  @patch
  JSFloat64Array get toJS =>
      JSFloat64Array._(js_types.JSFloat64ArrayType(_tdToJS(this, 8)));
}

@patch
extension JSFloat64ArrayToFloat64List on JSFloat64Array {
  @patch
  Float64List get toDart =>
      _tdFromJS((this as JSValue).handle, 8) as Float64List;
}

@patch
extension ByteBufferToJSArrayBuffer on ByteBuffer {
  @patch
  JSArrayBuffer get toJS => JSArrayBuffer._(
      js_types.JSArrayBufferType(_tdToJS(asUint8List(), 9)));
}

@patch
extension JSArrayBufferToByteBuffer on JSArrayBuffer {
  @patch
  ByteBuffer get toDart =>
      (_tdFromJS((this as JSValue).handle, 0) as Uint8List).buffer;
}

@patch
extension ByteDataToJSDataView on ByteData {
  @patch
  JSDataView get toJS => JSDataView._(
      js_types.JSDataViewType(_tdToJS(buffer.asUint8List(
          offsetInBytes, lengthInBytes), 10)));
}

@patch
extension JSDataViewToByteData on JSDataView {
  @patch
  ByteData get toDart =>
      (_tdFromJS((this as JSValue).handle, 0) as Uint8List).buffer.asByteData();
}

// === Predicates used by the SharedInteropTransformer (Phase 3) ===
//
// The shared transformer emits calls to these top-level helpers when it
// lowers `@JS()` extension-type member accesses. For the Phase 1 VM
// backend everything that lives on the JS side is just a [JSValue] box,
// so the predicates collapse to a single runtime-type check. Boxed Dart
// objects (`JSBoxedDartObject`) and exported Dart functions are out of
// scope for Phase 1; the predicates return false until those land.

bool _isJSAny(Object? any) => any is JSValue;
bool _isNullableJSAny(Object? any) => any == null || _isJSAny(any);

bool _isJSObject(Object? any) => any is JSValue;
bool _isNullableJSObject(Object? any) => any == null || _isJSObject(any);

bool _isJSBoxedDartObject(Object? any) => false;
bool _isNullableJSBoxedDartObject(Object? any) => any == null;

bool _isJSExportedDartFunction(Object? any) => false;
bool _isNullableJSExportedDartFunction(Object? any) => any == null;
