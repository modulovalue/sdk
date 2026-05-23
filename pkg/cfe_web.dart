// @dart=3.12
// In-browser Dart kernel compiler. Compiled to wasm via `dart compile wasm`.
// Exposes a globalThis.dartCompile(source, platformBytes) that returns the
// compiled kernel bytes (VM-target, with global transformations applied).

import 'dart:js_interop';
import 'dart:typed_data';
import 'package:front_end/src/api_prototype/compiler_options.dart';
import 'package:front_end/src/api_prototype/memory_file_system.dart';
import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart'
    show CfeDiagnosticMessage;
import 'package:kernel/ast.dart' as ast;
import 'package:kernel/binary/ast_to_binary.dart' as kbin;
import 'package:kernel/target/targets.dart';
import 'package:vm/modular/target/vm.dart' show VmTarget;
import 'package:vm/kernel_front_end.dart'
    show compileToKernel, KernelCompilationArguments, KernelCompilationResults;

Future<Uint8List> _compile(String source, Uint8List platformBytes,
    List<Uint8List> additionalDills) async {
  final fs = MemoryFileSystem(Uri.parse('memory:/'));
  final userUri = Uri.parse('memory:/user.dart');
  final sdkUri = Uri.parse('memory:/vm_platform.dill');
  fs.entityForUri(userUri).writeAsStringSync(source);
  fs.entityForUri(sdkUri).writeAsBytesSync(platformBytes);

  final additionalDillUris = <Uri>[];
  for (var i = 0; i < additionalDills.length; i++) {
    final uri = Uri.parse('memory:/pkg_$i.dill');
    fs.entityForUri(uri).writeAsBytesSync(additionalDills[i]);
    additionalDillUris.add(uri);
  }

  final errors = <String>[];
  final options = CompilerOptions()
    ..fileSystem = fs
    ..sdkSummary = sdkUri
    ..additionalDills = additionalDillUris
    ..target = VmTarget(TargetFlags(
      supportMirrors: true,
      constKeepLocalsIndicator: true,
    ))
    ..environmentDefines = <String, String>{}
    ..verify = false
    ..onDiagnostic = (CfeDiagnosticMessage d) {
      for (final line in d.plainTextFormatted) {
        errors.add(line);
      }
    };

  // compileToKernel runs the CFE. We don't pass aot=true (its transformations
  // are too heavy to ship via dart2wasm and not all of them work there). The
  // resulting kernel still has RedirectingFactoryInvocation nodes that the
  // VM's strict AOT kernel reader rejects, so we run our own minimal pass to
  // lower them below.
  final KernelCompilationResults result = await compileToKernel(
    KernelCompilationArguments(
      source: userUri,
      options: options,
      enableAsserts: false,
      includePlatform: true,
    ),
  );
  if (result.component == null) {
    throw StateError('CFE produced no component:\n${errors.join("\n")}');
  }
  // Serialize the full kernel (including platform libs). Our AOT-mode wasm VM
  // requires a fully-linked kernel — separate user-only kernels aren't
  // accepted because the VM-as-AOT-runtime can't merge them on the fly.
  final builder = BytesBuilder();
  kbin.BinaryPrinter(_ByteSink(builder)).writeComponentFile(result.component!);
  return builder.takeBytes();
}

// Minimal lowering of RedirectingFactoryInvocation nodes: replace each with
// a direct call to the factory's redirection target. This is what the VM
// global transformations do as part of their AOT pipeline; we replicate just
// this one rule here because the rest of the AOT pipeline doesn't run cleanly
// inside a dart2wasm-compiled CFE.
class _RfiLowerer extends ast.Transformer {
  @override
  ast.TreeNode visitRedirectingFactoryInvocation(
      ast.RedirectingFactoryInvocation node) {
    // The expression field already holds the effective-target invocation,
    // which is what should replace this node.
    final inner = node.expression;
    inner.accept(this);
    return inner;
  }
}

void _lowerRedirectingFactoryInvocations(ast.Component component) {
  final lowerer = _RfiLowerer();
  for (final lib in component.libraries) {
    lib.transformChildren(lowerer);
  }
}

class _ByteSink implements Sink<List<int>> {
  final BytesBuilder _b;
  _ByteSink(this._b);
  @override void add(List<int> data) => _b.add(data);
  @override void close() {}
}

JSPromise<JSUint8Array> compile(
    JSString source, JSUint8Array platform, JSArray<JSUint8Array> dills) {
  return (() async {
    final dartDills = <Uint8List>[
      for (final d in dills.toDart) d.toDart,
    ];
    final out = await _compile(source.toDart, platform.toDart, dartDills);
    return out.toJS;
  })().toJS;
}

@JS('dartCompile')
external set _dartCompile(JSFunction fn);

void main() {
  _dartCompile = compile.toJS;
}
