// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:_internal' show patch;
import 'dart:_js_helper' as _h show JS, JSh, JSValue;
import 'dart:js_interop';

@patch
extension JSObjectUnsafeUtilExtension on JSObject {
  @patch
  JSBoolean hasProperty(JSAny property) =>
      _h.JS<bool>('bool', 'a[1] in a[0]', this, property).toJS;

  @patch
  T getProperty<T extends JSAny?>(JSAny property) =>
      _h.JSh('a[0][a[1]]', this, property) as T;

  @patch
  void setProperty(JSAny property, JSAny? value) =>
      _h.JS<void>('void', 'a[0][a[1]] = a[2]', this, property, value);

  @patch
  JSAny? _callMethod(
    JSAny method, [
    JSAny? arg1,
    JSAny? arg2,
    JSAny? arg3,
    JSAny? arg4,
  ]) {
    if (arg1 == null) {
      return _h.JSh('a[0][a[1]]()', this, method) as JSAny?;
    } else if (arg2 == null) {
      return _h.JSh('a[0][a[1]](a[2])', this, method, arg1) as JSAny?;
    } else if (arg3 == null) {
      return _h.JSh('a[0][a[1]](a[2], a[3])', this, method, arg1, arg2)
          as JSAny?;
    } else if (arg4 == null) {
      return _h.JSh(
              'a[0][a[1]](a[2], a[3], a[4])', this, method, arg1, arg2, arg3)
          as JSAny?;
    }
    return _h.JSh('a[0][a[1]](a[2], a[3], a[4], a[5])', this, method, arg1,
        arg2, arg3, arg4) as JSAny?;
  }

  @patch
  JSAny? _callMethodVarArgs(JSAny method, [List<JSAny?>? arguments]) {
    // Build a JS-side array from the Dart list, then .apply with it.
    if (arguments == null || arguments.isEmpty) {
      return _h.JSh('a[0][a[1]]()', this, method) as JSAny?;
    }
    final arr = _h.JSh('[]')!;
    for (var i = 0; i < arguments.length; i++) {
      _h.JS<void>('void', 'a[0][a[1]] = a[2]', arr, i, arguments[i]);
    }
    return _h.JSh('a[0][a[1]].apply(a[0], a[2])', this, method, arr) as JSAny?;
  }

  @patch
  JSBoolean delete(JSAny property) =>
      _h.JS<bool>('bool', 'delete a[0][a[1]]', this, property).toJS;
}

@patch
extension JSFunctionUnsafeUtilExtension on JSFunction {
  @patch
  JSObject _callAsConstructor([
    JSAny? arg1,
    JSAny? arg2,
    JSAny? arg3,
    JSAny? arg4,
  ]) {
    if (arg1 == null) {
      return _h.JSh('new (a[0])()', this) as JSObject;
    } else if (arg2 == null) {
      return _h.JSh('new (a[0])(a[1])', this, arg1) as JSObject;
    } else if (arg3 == null) {
      return _h.JSh('new (a[0])(a[1], a[2])', this, arg1, arg2) as JSObject;
    } else if (arg4 == null) {
      return _h.JSh('new (a[0])(a[1], a[2], a[3])', this, arg1, arg2, arg3)
          as JSObject;
    }
    return _h.JSh(
            'new (a[0])(a[1], a[2], a[3], a[4])', this, arg1, arg2, arg3, arg4)
        as JSObject;
  }

  @patch
  JSObject _callAsConstructorVarArgs([List<JSAny?>? arguments]) {
    if (arguments == null || arguments.isEmpty) {
      return _h.JSh('new (a[0])()', this) as JSObject;
    }
    final arr = _h.JSh('[]')!;
    for (var i = 0; i < arguments.length; i++) {
      _h.JS<void>('void', 'a[0][a[1]] = a[2]', arr, i, arguments[i]);
    }
    return _h.JSh(
            '(function(c, args) {'
            'return new (Function.prototype.bind.apply(c, [null].concat(args)));'
            '})(a[0], a[1])',
            this,
            arr) as JSObject;
  }
}
