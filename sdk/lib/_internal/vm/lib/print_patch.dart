// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of "internal_patch.dart";

// A print-closure gets a String that should be printed. In general the
// string is a line, but it may contain "\n" characters.
typedef void _PrintClosure(String line);

@patch
void printToConsole(String line) {
  _printClosure(line);
}

void _unsupportedPrint(String line) {
  // Route through an embedder-provided native. In the wasm build the embedder
  // (dart_il_extract.cc) registers an implementation via Dart_SetNativeResolver
  // that appends to the IL capture buffer. For embedders that don't register
  // it, this becomes an unresolved native at runtime — better than a throw
  // because most embedders that care will register it.
  _embedderPrintString(line);
}

@pragma("vm:external-name", "EmbedderPrintString")
external void _embedderPrintString(String s);

// A Timer implementation for embedders without a real event loop (e.g. the
// wasm IL extractor). The callback is scheduled as a microtask; before
// running it we busy-wait for the duration via an embedder-provided native.
// The UI thread is blocked during the wait, but `Future.delayed(D)` actually
// takes D wall-clock milliseconds, which is the visible promise.
class _ImmediateTimer implements Timer {
  final int _ms;
  final void Function(Timer) _callback;
  final bool _periodic;
  bool _cancelled = false;
  int _tick = 0;
  _ImmediateTimer(this._ms, this._callback, this._periodic) {
    scheduleMicrotask(_fire);
  }
  void _fire() {
    if (_cancelled) return;
    if (_ms > 0) _embedderSleep(_ms);
    if (_cancelled) return;
    _tick++;
    _callback(this);
    if (_periodic && !_cancelled) {
      scheduleMicrotask(_fire);
    }
  }
  @override
  void cancel() {
    _cancelled = true;
  }
  @override
  int get tick => _tick;
  @override
  bool get isActive => !_cancelled;
}

@pragma("vm:external-name", "EmbedderSleep")
external void _embedderSleep(int ms);

Timer _immediateTimerFactory(int ms, void Function(Timer) cb, bool periodic) {
  return _ImmediateTimer(ms, cb, periodic);
}

@pragma("vm:entry-point", "call")
void _installImmediateTimerFactory() {
  VMLibraryHooks.timerFactory = _immediateTimerFactory;
}

// _printClosure can be overwritten by the embedder to supply a different
// print implementation.
@pragma("vm:entry-point", "set")
@pragma("vm:shared")
_PrintClosure _printClosure = _unsupportedPrint;
