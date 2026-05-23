// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// VM backend patch for `dart:js_util`.
///
/// Phase 3 of the Dart-Live `package:web` story: the `JsUtilOptimizer` from
/// `pkg/_js_interop_checks` lowers `@JS()` extension-type method calls into
/// calls to these top-level helpers, so they must all *exist* in
/// `dart:js_util`. The implementations here delegate to our existing
/// `dart:js_interop_unsafe` patches (which run on the JS-handle table
/// maintained by the embedder), so the lowered code "just works" at runtime
/// without us re-implementing the entire interop pipeline.
///
/// Members that the transformer references but that user code typically
/// doesn't hit yet (function exports, Promise/Future conversion, deep
/// jsify/dartify) are stubbed with `UnimplementedError`. They'll get real
/// bodies in Phase 2.

import 'dart:_internal' show patch;
import 'dart:_js_helper' as _h
    show JS, JSh, JSValue, exportDartFunctionAsJS;
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe' as unsafe;

// --- Object marshalling helpers -------------------------------------------

// Convert a Dart-side [Object] (which is either a [JSValue] handle or a
// primitive that needs wrapping) into the form our embedder template
// expects to see when it appears as a JS expression argument.
//
// `dart:js_interop_unsafe` already does this implicitly for its public API
// (the `JS` helper accepts primitives and JSValues), so we just pass
// through. The cast to JSAny? makes the static types line up for the
// `extension JSObjectUnsafeUtilExtension on JSObject` patches.
// At runtime every `JS*` extension type is just a `JSValue` box. The
// JsUtilOptimizer passes us:
//   - the receiver as Object (a JSValue at runtime, after StaticInteropEraser)
//   - the member name as a Dart String (the literal from the original
//     external declaration)
//   - argument values which are usually either Dart primitives or JSValues
// We need to (a) accept JSValues as-is and (b) wrap Dart primitives so the
// unsafe-API templates see a real JS value rather than a raw Dart object.
JSObject _asJSObject(Object o) {
  if (o is JSObject) return o;
  // Assume it's a JSValue masquerading as Object after class erasure.
  return o as JSObject;
}

JSAny _asJSAny(Object o) {
  if (o is JSAny) return o;
  if (o is String) return o.toJS;
  if (o is num) return o.toJS;
  if (o is bool) return o.toJS;
  return o as JSAny;
}

JSAny? _asJSAnyOrNull(Object? o) {
  if (o == null) return null;
  return _asJSAny(o);
}

JSFunction _asJSFunction(Object o) => o as JSFunction;

@patch
dynamic jsify(Object? object) {
  // Phase-1 dumb implementation: only Maps and Iterables get a JS form;
  // primitives are passed through unchanged. Real recursive jsify is
  // Phase-2 polish.
  if (object == null) return null;
  if (object is bool || object is num || object is String) return object;
  if (object is _h.JSValue) return object;
  if (object is Map) {
    final obj = _h.JSh('({})')!;
    object.forEach((k, v) {
      _h.JS<void>('void', 'a[0][a[1]] = a[2]', obj, k, jsify(v));
    });
    return obj;
  }
  if (object is Iterable) {
    final arr = _h.JSh('[]')!;
    var i = 0;
    for (final v in object) {
      _h.JS<void>('void', 'a[0][a[1]] = a[2]', arr, i++, jsify(v));
    }
    return arr;
  }
  return object;
}

@patch
Object get globalThis => _h.JSValue(0);

@patch
T newObject<T>() => _h.JSh('({})')! as T;

@patch
bool hasProperty(Object o, Object name) =>
    unsafe.JSObjectUnsafeUtilExtension(_asJSObject(o))
        .hasProperty(_asJSAny(name))
        .toDart;

@patch
T getProperty<T>(Object o, Object name) {
  // The signature is generic over T (Dart String, num, bool, JSObject, ...).
  // The unsafe helper's `getProperty` always wraps the result in a JSValue
  // handle — that's right for `T extends JSAny?` but wrong for primitive T.
  // Calling the embedder JS bridge directly preserves Dart primitives
  // (the bridge returns them as Dart values), and JS objects come back as
  // JSValue handles, which cast cleanly to JSObject / JSValue / JSAny T's.
  return _h.JS<dynamic>('', 'a[0][a[1]]', o, _asJSAny(name)) as T;
}

@patch
T setProperty<T>(Object o, Object name, T? value) {
  unsafe.JSObjectUnsafeUtilExtension(_asJSObject(o))
      .setProperty(_asJSAny(name), _asJSAnyOrNull(value));
  return value as T;
}

@patch
T callMethod<T>(Object o, Object method, List<Object?> args) {
  // Same reasoning as [getProperty]: return primitives as Dart primitives
  // and objects as JSValue, so the `as T` cast lands on the right shape.
  // We unfortunately can't do `a[0][a[1]](...a[2])` because that needs the
  // args as a real JS Array; build one element-by-element.
  if (args.isEmpty) {
    return _h.JS<dynamic>('', 'a[0][a[1]]()', o, _asJSAny(method)) as T;
  }
  final arr = _h.JSh('[]')!;
  for (var i = 0; i < args.length; i++) {
    _h.JS<void>('void', 'a[0][a[1]] = a[2]', arr, i, _asJSAnyOrNull(args[i]));
  }
  return _h.JS<dynamic>(
      '', 'a[0][a[1]].apply(a[0], a[2])', o, _asJSAny(method), arr) as T;
}

@patch
bool instanceof(Object? o, Object type) {
  if (o == null) return false;
  return _h.JS<bool>('bool', 'a[0] instanceof a[1]', o, type);
}

@patch
T callConstructor<T>(Object constr, List<Object?>? arguments) {
  final jsArgs = arguments == null
      ? <JSAny?>[]
      : <JSAny?>[for (final a in arguments) _asJSAnyOrNull(a)];
  return unsafe.JSFunctionUnsafeUtilExtension(_asJSFunction(constr))
      .callAsConstructorVarArgs<JSObject>(jsArgs) as T;
}

// --- JS arithmetic operators (small surface) ------------------------------

T _binop<T>(String op, Object? a, Object? b) =>
    _h.JS<dynamic>('', 'a[0] $op a[1]', a, b) as T;

@patch
T add<T>(Object? first, Object? second) => _binop<T>('+', first, second);
@patch
T subtract<T>(Object? first, Object? second) => _binop<T>('-', first, second);
@patch
T multiply<T>(Object? first, Object? second) => _binop<T>('*', first, second);
@patch
T divide<T>(Object? first, Object? second) => _binop<T>('/', first, second);
@patch
T exponentiate<T>(Object? first, Object? second) =>
    _binop<T>('**', first, second);
@patch
T modulo<T>(Object? first, Object? second) => _binop<T>('%', first, second);

@patch
bool equal<T>(Object? first, Object? second) =>
    _binop<bool>('==', first, second);
@patch
bool strictEqual<T>(Object? first, Object? second) =>
    _binop<bool>('===', first, second);
@patch
bool notEqual<T>(Object? first, Object? second) =>
    _binop<bool>('!=', first, second);
@patch
bool strictNotEqual<T>(Object? first, Object? second) =>
    _binop<bool>('!==', first, second);
@patch
bool greaterThan<T>(Object? first, Object? second) =>
    _binop<bool>('>', first, second);
@patch
bool greaterThanOrEqual<T>(Object? first, Object? second) =>
    _binop<bool>('>=', first, second);
@patch
bool lessThan<T>(Object? first, Object? second) =>
    _binop<bool>('<', first, second);
@patch
bool lessThanOrEqual<T>(Object? first, Object? second) =>
    _binop<bool>('<=', first, second);

@patch
bool typeofEquals<T>(Object? o, String type) =>
    _h.JS<bool>('bool', 'typeof a[0] === a[1]', o, type);

@patch
T not<T>(Object? o) => _h.JS<dynamic>('', '!a[0]', o) as T;
@patch
bool isTruthy<T>(Object? o) => _h.JS<bool>('bool', '!!a[0]', o);
@patch
T or<T>(Object? first, Object? second) =>
    _h.JS<dynamic>('', 'a[0] || a[1]', first, second) as T;
@patch
T and<T>(Object? first, Object? second) =>
    _h.JS<dynamic>('', 'a[0] && a[1]', first, second) as T;

@patch
bool delete<T>(Object o, Object property) =>
    unsafe.JSObjectUnsafeUtilExtension(_asJSObject(o))
        .delete(_asJSAny(property))
        .toDart;

@patch
num unsignedRightShift(Object? leftOperand, Object? rightOperand) =>
    _h.JS<num>('num', 'a[0] >>> a[1]', leftOperand, rightOperand);

// --- Reflection-ish (small surface) ---------------------------------------

@patch
Object? objectGetPrototypeOf(Object? object) =>
    _h.JSh('Object.getPrototypeOf(a[0])', object);

@patch
Object? get objectPrototype => _h.JSValue(0); // not really used

@patch
List<Object?> objectKeys(Object? object) {
  final arr = _h.JSh('Object.keys(a[0])', object)!;
  final n = _h.JS<int>('int', 'a[0].length', arr);
  return <Object?>[
    for (var i = 0; i < n; i++)
      _h.JSh('a[0][a[1]]', arr, i),
  ];
}

@patch
bool isJavaScriptArray(value) =>
    _h.JS<bool>('bool', 'Array.isArray(a[0])', value);

@patch
bool isJavaScriptSimpleObject(value) => _h.JS<bool>(
      'bool',
      "Object.getPrototypeOf(a[0]) === Object.prototype",
      value,
    );

@patch
Object? dartify(Object? o) {
  // Mirror dart2wasm: primitives pass through; everything else is opaque.
  if (o == null) return null;
  if (o is bool || o is num || o is String) return o;
  return o;
}

@patch
Future<T> promiseToFuture<T>(Object jsPromise) {
  // Real Promise.then plumbing is Phase-2 work. For now, give the user a
  // clear error rather than silently hanging.
  throw UnimplementedError(
      'promiseToFuture is not implemented in the Phase 1 VM JS interop '
      'patch yet. Coming in Phase 2.');
}

@patch
T createStaticInteropMock<T extends Object, U extends Object>(
  U proto, [
  Object? interceptors,
]) {
  throw UnimplementedError(
      'createStaticInteropMock is not supported on the VM JS interop '
      'backend.');
}

// --- "Trust-types" fast-path variants the optimizer references -----------

@pragma('vm:prefer-inline')
T _getPropertyTrustType<T>(Object o, Object name) => getProperty<T>(o, name);

@pragma('vm:prefer-inline')
T _callMethodTrustType<T>(Object o, Object method, List<Object?> args) =>
    callMethod<T>(o, method, args);

@pragma('vm:prefer-inline')
T _setPropertyUnchecked<T>(Object o, Object name, T? value) =>
    setProperty<T>(o, name, value);

// Per-arity unchecked variants (the optimizer prefers these for inlining).
// We just delegate to the general callMethod for now.
T _callMethodUnchecked0<T>(Object o, Object method) =>
    callMethod<T>(o, method, const []);
T _callMethodUnchecked1<T>(Object o, Object method, Object? a) =>
    callMethod<T>(o, method, [a]);
T _callMethodUnchecked2<T>(Object o, Object method, Object? a, Object? b) =>
    callMethod<T>(o, method, [a, b]);
T _callMethodUnchecked3<T>(
        Object o, Object method, Object? a, Object? b, Object? c) =>
    callMethod<T>(o, method, [a, b, c]);
T _callMethodUnchecked4<T>(
        Object o, Object method, Object? a, Object? b, Object? c, Object? d) =>
    callMethod<T>(o, method, [a, b, c, d]);

T _callMethodUncheckedTrustType0<T>(Object o, Object method) =>
    _callMethodUnchecked0<T>(o, method);
T _callMethodUncheckedTrustType1<T>(Object o, Object method, Object? a) =>
    _callMethodUnchecked1<T>(o, method, a);
T _callMethodUncheckedTrustType2<T>(
        Object o, Object method, Object? a, Object? b) =>
    _callMethodUnchecked2<T>(o, method, a, b);
T _callMethodUncheckedTrustType3<T>(
        Object o, Object method, Object? a, Object? b, Object? c) =>
    _callMethodUnchecked3<T>(o, method, a, b, c);
T _callMethodUncheckedTrustType4<T>(
        Object o, Object method, Object? a, Object? b, Object? c, Object? d) =>
    _callMethodUnchecked4<T>(o, method, a, b, c, d);

T _callConstructorUnchecked0<T>(Object constr) =>
    callConstructor<T>(constr, const []);
T _callConstructorUnchecked1<T>(Object constr, Object? a) =>
    callConstructor<T>(constr, [a]);
T _callConstructorUnchecked2<T>(Object constr, Object? a, Object? b) =>
    callConstructor<T>(constr, [a, b]);
T _callConstructorUnchecked3<T>(Object constr, Object? a, Object? b, Object? c) =>
    callConstructor<T>(constr, [a, b, c]);
T _callConstructorUnchecked4<T>(
        Object constr, Object? a, Object? b, Object? c, Object? d) =>
    callConstructor<T>(constr, [a, b, c, d]);

// --- Function export (Phase 2a) -------------------------------------------
//
// The JsUtilOptimizer rewrites `myFn.toJS` into one of these arity-specific
// helpers. They all delegate to the dart:_js_helper registry, which builds
// a JS function via `Embedder_JS_MakeCallback`.

Object _functionToJS0(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJS1(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJS2(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJS3(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJS4(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJS5(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSN(Function f, int maxArgs) =>
    _h.exportDartFunctionAsJS(f);

// `captureThis` variants. Phase 2a doesn't forward JS's `this` yet — the
// callback ignores it. Code targeting `addEventListener`-style APIs (most
// of `package:web`) doesn't need `this`.
Object _functionToJSCaptureThis0(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSCaptureThis1(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSCaptureThis2(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSCaptureThis3(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSCaptureThis4(Function f) => _h.exportDartFunctionAsJS(f);
Object _functionToJSCaptureThisN(Function f, int maxArgs) =>
    _h.exportDartFunctionAsJS(f);

// Reverse direction (unwrap a Dart-exported JS function back into the
// underlying Dart Function). Not supported yet.
Object _jsFunctionToDart(Object f) => throw UnimplementedError(
    'Recovering a Dart Function from a JSExportedDartFunction is not yet '
    'supported on the VM backend.');

@patch
F allowInterop<F extends Function>(F f) => f;
