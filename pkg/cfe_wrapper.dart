// In-VM kernel compiler wrapper. Takes a Dart source string from C++ via a
// native callback, runs the CFE against an in-memory file system, returns the
// serialized kernel bytes via another native callback.

import 'dart:typed_data';
import 'package:front_end/src/api_prototype/compiler_options.dart';
import 'package:front_end/src/api_prototype/kernel_generator.dart';
import 'package:front_end/src/api_prototype/memory_file_system.dart';
import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart'
    show CfeDiagnosticMessage;
import 'package:kernel/binary/ast_to_binary.dart' show BinaryPrinter;
import 'package:kernel/target/targets.dart';
import 'package:vm/modular/target/vm.dart' show VmTarget;

@pragma('vm:external-name', 'CfeGetSource')
external String _cfeGetSource();

@pragma('vm:external-name', 'CfeGetPlatform')
external Uint8List _cfeGetPlatform();

@pragma('vm:external-name', 'CfePutKernel')
external void _cfePutKernel(Uint8List bytes);

@pragma('vm:external-name', 'CfeReportError')
external void _cfeReportError(String msg);

class _ByteSink implements Sink<List<int>> {
  final BytesBuilder _builder = BytesBuilder();
  @override
  void add(List<int> data) => _builder.add(data);
  @override
  void close() {}
  Uint8List takeBytes() => _builder.takeBytes();
}

@pragma('vm:entry-point', 'call')
Future<void> compileSource() async {
  final source = _cfeGetSource();
  final platform = _cfeGetPlatform();
  final fs = MemoryFileSystem(Uri.parse('memory:/'));
  final userUri = Uri.parse('memory:/user.dart');
  final sdkUri = Uri.parse('memory:/vm_platform.dill');
  fs.entityForUri(userUri).writeAsStringSync(source);
  fs.entityForUri(sdkUri).writeAsBytesSync(platform);

  final options = CompilerOptions()
    ..fileSystem = fs
    ..sdkSummary = sdkUri
    ..target = VmTarget(TargetFlags())
    ..environmentDefines = <String, String>{}
    ..verify = false
    ..onDiagnostic = (CfeDiagnosticMessage d) {
      for (final line in d.plainTextFormatted) {
        _cfeReportError(line);
      }
    };

  final result = await kernelForProgram(userUri, options);
  if (result == null || result.component == null) {
    _cfeReportError('CFE returned no component');
    return;
  }
  final sink = _ByteSink();
  BinaryPrinter(sink).writeComponentFile(result.component!);
  _cfePutKernel(sink.takeBytes());
}

void main() {
  // entrypoint stub; the actual work happens via compileSource() invoked
  // from C++ after the kernel is loaded.
}
