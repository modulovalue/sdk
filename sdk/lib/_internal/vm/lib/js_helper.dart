// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Internal helper for the VM's `dart:js_interop` backend patch.
///
/// In the Dart-VM-on-Wasm embedder, JavaScript values are addressed by
/// integer handles into a JS-side handle table maintained by the embedder.
/// All [JSValue] objects are simple boxes over that handle. JS interop calls
/// from Dart go through [JS], which marshals arguments, evaluates a JS
/// template, and wraps the result.
///
/// Unlike dart2js (which lowers `JS('expr', #, #)` at compile time) and
/// dart2wasm (which uses `WasmExternRef`), this implementation is a plain
/// runtime function backed by an embedder native.
library dart._js_helper;

import 'dart:_internal' show patch;

/// A JS value, identified by an integer handle into the embedder's JS-side
/// table. Handle `0` is reserved for `globalThis`.
class JSValue {
  final int handle;
  const JSValue(this.handle);

  static const JSValue undefined = JSValue(-1);
  static const JSValue dartNull = JSValue(-2);

  bool get isUndefined => handle == -1;
  bool get isNull => handle == -2;
}

/// Run a snippet of JavaScript with [args] substituted in for each `#`
/// placeholder in [codeTemplate].
///
/// Args that are [JSValue] are passed by handle; primitives (`int`, `double`,
/// `bool`, `String`) are forwarded as their Dart values. The result is:
///   * a [JSValue] if the JS expression evaluates to an object/function,
///   * a Dart primitive if the JS result is a primitive,
///   * `null` if the JS result is `null` or `undefined`.
///
/// The [returnType] argument is ignored here. It matches the dart2js/dart2wasm
/// signature for source-compatibility, where the compiler uses it as a type
/// hint.
T JS<T>(
  String returnType,
  String codeTemplate, [
  Object? a0,
  Object? a1,
  Object? a2,
  Object? a3,
  Object? a4,
  Object? a5,
  Object? a6,
  Object? a7,
]) {
  final n = _argCount(a0, a1, a2, a3, a4, a5, a6, a7);
  final args = List<Object?>.filled(n, null);
  if (n > 0) args[0] = a0;
  if (n > 1) args[1] = a1;
  if (n > 2) args[2] = a2;
  if (n > 3) args[3] = a3;
  if (n > 4) args[4] = a4;
  if (n > 5) args[5] = a5;
  if (n > 6) args[6] = a6;
  if (n > 7) args[7] = a7;
  // Encode args as a parallel list of {kind, value} entries.
  // kind: 'p' = primitive, 'h' = JS handle.
  // Encoded args: parallel kind/value pairs.
  //   kind 'h' → JS handle; value is the int handle as a decimal string
  //   kind 's' → Dart String; value is the string verbatim
  //   kind 'p' → JSON literal for primitives (null, true, false, numbers)
  final encoded = <String>[];
  for (final a in args) {
    if (a is JSValue) {
      encoded.add('h');
      encoded.add(a.handle.toString());
    } else if (a == null) {
      encoded.add('p');
      encoded.add('null');
    } else if (a is bool) {
      encoded.add('p');
      encoded.add(a ? 'true' : 'false');
    } else if (a is num) {
      encoded.add('p');
      encoded.add(a.toString());
    } else if (a is String) {
      encoded.add('s');
      encoded.add(a);
    } else {
      encoded.add('p');
      encoded.add(a.toString());
    }
  }
  final result = _jsRun(codeTemplate, encoded);
  // Native returns a tagged 2-list: [kind, value].
  //   'n' → null    (returned as null itself, value ignored)
  //   'b' → bool
  //   'i' → int
  //   'd' → double
  //   's' → String
  //   'h' → handle int → wrap as JSValue
  if (result == null) return null as T;
  if (result is List && result.length == 2) {
    final kind = result[0];
    final value = result[1];
    if (kind == 'h') return JSValue(value as int) as T;
    return value as T;
  }
  return result as T;
}

int _argCount(Object? a0, Object? a1, Object? a2, Object? a3,
              Object? a4, Object? a5, Object? a6, Object? a7) {
  // dart2js's JS() infers arity from how many positional args were passed.
  // We can't tell "passed null" vs "not passed" so we just always pack 8.
  // The JS-side runtime ignores trailing args that aren't referenced by
  // the template.
  return 8;
}

/// Embedder-implemented: take a template and a flattened
/// [kind, value, kind, value, ...] argument array, substitute each `#` in
/// the template with the next argument (handle reference or primitive
/// literal), eval the result, and return either:
///   * a [JSValue] wrapping a new handle, or
///   * a Dart primitive (int / double / bool / String / null) for JS
///     primitive results.
@pragma("vm:external-name", "Embedder_JS_Run")
external Object? _jsRun(String template, List<String> args);

/// Return a handle representing the JS `globalThis`. Always handle 0.
Object globalThisRaw() => JSValue(0);

/// Used by the JS-interop transformer (`JsUtilOptimizer`) when lowering
/// `@JS()` top-level / class-static external members. The transformer
/// rewrites e.g. `external String get title;` on a `@JS('document')`
/// declaration into `staticInteropGlobalContext.getProperty('document').
/// getProperty('title')`. For us, `staticInteropGlobalContext` is just
/// our `globalContext` — there's no distinct "static-interop" environment.
Object get staticInteropGlobalContext => JSValue(0);

// ============================================================
// Phase 2a: exporting Dart functions as callable JS functions.
//
// `Function.toJS` (from dart:js_interop) is implemented by:
//   1. Registering the Dart closure in [_dartCallbacks], getting an int id.
//   2. Calling [_makeJSCallback(id)] which is implemented natively. The
//      native creates a JS function that calls back into wasm through
//      the exported `dart_il_invoke_dart_callback` thunk, passing the id
//      plus the JS arguments as a list of handles.
//   3. The thunk re-enters Dart and calls [_invokeDartCallback].
//
// Arguments arriving from JS are passed to the Dart closure as JSValue
// handles (or Dart null for JS null). The Dart closure can downcast them
// to whatever extension type the static signature claims.
// ============================================================

// We box each exported Dart Function as a monomorphic `dynamic Function(
// List<Object?>)` so the JS-to-Dart bridge does *not* go through
// `Function.apply` on the hot path. `Function.apply` did the right thing
// on the first invocation but tripped a stale-function-table indirect
// call on the second one (observed as
// "RuntimeError: null function or function signature mismatch"). Boxing
// to a fixed arity / fixed shape sidesteps that.
typedef _BoxedCallback = Object? Function(List<Object?> args);

final Map<int, _BoxedCallback> _dartCallbacks = <int, _BoxedCallback>{};
int _nextDartCallbackId = 1;

_BoxedCallback _box(Function f) => (List<Object?> args) {
      // Dispatch per arity; fall back to Function.apply for rare cases.
      switch (args.length) {
        case 0:
          return (f as dynamic)();
        case 1:
          return (f as dynamic)(args[0]);
        case 2:
          return (f as dynamic)(args[0], args[1]);
        case 3:
          return (f as dynamic)(args[0], args[1], args[2]);
        case 4:
          return (f as dynamic)(args[0], args[1], args[2], args[3]);
        default:
          return Function.apply(f, args);
      }
    };

/// Register a Dart [f] for JS to call back. Returns a JS function handle.
JSValue exportDartFunctionAsJS(Function f) {
  final id = _nextDartCallbackId++;
  _dartCallbacks[id] = _box(f);
  return _makeJSCallback(id);
}

/// C++ thunk lives in dart_il_extract.cc: Embedder_JS_MakeCallback.
@pragma("vm:external-name", "Embedder_JS_MakeCallback")
external JSValue _makeJSCallback(int id);

/// Re-entry point for the JS-to-Dart bridge (called from C++).
/// args is a List<Object?> of JSValue handles (or null).
@pragma("vm:entry-point")
Object? _invokeDartCallback(int id, List<Object?> args) {
  final f = _dartCallbacks[id];
  if (f == null) {
    throw StateError('No Dart callback registered for id $id');
  }
  return f(args);
}

// === Phase 2b helper: JSPromise -> Future via pure JS callbacks + polling ===
//
// The Dart-side patch in js_interop_patch.dart delegates here so the
// heavy lifting lives outside an extension-type method body (which seems
// to trip a VM dispatch bug; see the note in the patch).
//
// We register two pure-JS callbacks (built via `new Function(...)`) that
// mutate a JS slot object. Dart then `await`s short delays until the slot
// transitions out of "pending". During each delay the wasm task is yielded
// back to JS (via the embedder sleep / Asyncify) so the JS event loop has
// a chance to fire the Promise's then-callbacks.
@pragma("vm:entry-point")
Future<Object?> promiseToDartFuture(JSValue promise) async {
  // Build a slot via `({state:"pending"})`.
  final slot = JS<dynamic>('JSValue', '({state:"pending"})');
  // Build the resolve / reject JS helpers.
  final onResolve = JS<dynamic>(
      'JSValue',
      'new Function("slot","v","slot.value = v; slot.state = \\\"resolved\\\";").bind(null, a[0])',
      slot);
  final onReject = JS<dynamic>(
      'JSValue',
      'new Function("slot","e","slot.value = e; slot.state = \\\"rejected\\\";").bind(null, a[0])',
      slot);
  // Register them on the promise.
  JS<void>('void', 'a[0].then(a[1], a[2])', promise, onResolve, onReject);
  // Spin: yield, check.
  while (true) {
    final state = JS<String>('String', 'a[0].state', slot);
    if (state != 'pending') break;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  final state = JS<String>('String', 'a[0].state', slot);
  if (state == 'rejected') {
    final err = JSh('a[0].value', slot);
    if (err == null) throw 'NullRejectionException';
    throw err;
  }
  // Caller expects the JS-side value as a JSValue handle (extension types
  // erase to JSValue at runtime), so route through `JSh`. Returns Dart
  // `null` if the JS value is null/undefined.
  return JSh('a[0].value', slot);
}

/// Create a fresh, empty JS object and return a handle to it.
@pragma("vm:external-name", "Embedder_JS_NewObject")
external JSValue newObjectRaw();

/// Release a JS handle. Optional, used by finalizers; failing to call this
/// leaks the JS-side mapping until the embedder's table is reset.
@pragma("vm:external-name", "Embedder_JS_Release")
external void releaseJSHandle(int handle);

/// Like [JS], but always returns the JS result as a Dart-side [JSValue]
/// (the underlying representation of every `dart:js_interop` extension type),
/// or Dart `null` if the JS result is `null` / `undefined`.
///
/// Use this from the `dart:js_interop_unsafe` patches: methods like
/// `getProperty<T>` need to return *something castable to T*, and at runtime
/// every JS extension type erases to [JSValue]. Returning a raw Dart int
/// from `JS<dynamic>` would fail the cast.
JSValue? JSh(
  String codeTemplate, [
  Object? a0,
  Object? a1,
  Object? a2,
  Object? a3,
  Object? a4,
  Object? a5,
  Object? a6,
  Object? a7,
]) {
  // Wrap the user template so the JS engine pushes the result onto the
  // embedder's handle table (or returns -1 / -2 for undefined / null).
  final wrapped =
      '(function(){const v=($codeTemplate);'
      'if(v===undefined)return -1;'
      'if(v===null)return -2;'
      'globalThis.__jsTable.push(v);'
      'return globalThis.__jsTable.length-1;})()';
  final h = JS<dynamic>('int', wrapped, a0, a1, a2, a3, a4, a5, a6, a7);
  if (h is! int) return null;
  if (h == -1 || h == -2) return null;
  return JSValue(h);
}
