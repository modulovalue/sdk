// @dart=3.12
// Browser-side Dart analyzer with full resolution + type checking.
// Loads the prebuilt SDK summary (dart_sdk.sum) into a MemoryResourceProvider
// and analyzes user source against it. Compiled to wasm via dart2wasm.
//
// JS API (set on globalThis):
//   dartAnalyzerInit(Uint8Array sdkSummary): void
//   dartAnalyze(string source): string (JSON array of diagnostics)

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:_fe_analyzer_shared/src/base/diagnostic_message.dart'
    show Severity;
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:path/path.dart' as p;

const _userRoot = '/user';
const _userFile = '/user/lib/main.dart';
const _sdkSummaryPath = '/sdk.sum';

late MemoryResourceProvider _mem;
AnalysisContextCollectionImpl? _collection;

void _init(
    Uint8List sdkSummary,
    List<String> packageNames,
    List<Uint8List> packageSummaries) {
  // Force posix path style. dart2wasm in a browser sees Uri.base as the page
  // URL, which makes the default pkg_path style URL-based — that breaks the
  // analyzer's pathToUri roundtrip for /-rooted absolute paths.
  _mem = MemoryResourceProvider(context: p.Context(style: p.Style.posix));
  _mem.newFile(_sdkSummaryPath, '');
  // Write bytes via raw modify of the underlying map.
  _mem.modifyFile(_sdkSummaryPath, '');
  _mem.newFileWithBytes(_sdkSummaryPath, sdkSummary);

  // Register each provided package as a `package_config.json` entry pointing
  // at a stub directory, and write its analyzer summary bundle to a
  // librarySummaryPath. The summary itself holds the linked element data; the
  // stub dir only needs to exist for URI resolution.
  final pkgEntries = <Map<String, String>>[
    {'name': 'user', 'rootUri': '../', 'packageUri': 'lib/',
     'languageVersion': '3.0'},
  ];
  final summaryPaths = <String>[];
  for (var i = 0; i < packageNames.length; i++) {
    final name = packageNames[i];
    final root = '/ext_pkg_$i';
    _mem.newFile('$root/pubspec.yaml', 'name: $name\n');
    pkgEntries.add({
      'name': name,
      'rootUri': 'file://$root',
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
    final sumPath = '$root/lib.sum';
    _mem.newFileWithBytes(sumPath, packageSummaries[i]);
    summaryPaths.add(sumPath);
  }

  _mem.newFile('$_userRoot/pubspec.yaml', 'name: user\n');
  _mem.newFile(
    '$_userRoot/.dart_tool/package_config.json',
    jsonEncode({
      'configVersion': 2,
      'packages': pkgEntries,
    }),
  );
  _mem.newFile(_userFile, '// placeholder\n');
  _collection = AnalysisContextCollectionImpl(
    resourceProvider: _mem,
    includedPaths: [_userRoot],
    sdkPath: '/dart-sdk',
    sdkSummaryPath: _sdkSummaryPath,
    // Non-null librarySummaryPaths makes ContextBuilder initialize the
    // SummaryDataStore that the SDK summary then gets registered into.
    // Without this, externalSummaries is null and `dart:core` is "missing".
    librarySummaryPaths: summaryPaths,
  );
}

Future<String> _analyze(String source) async {
  if (_collection == null) {
    return jsonEncode([
      {'severity': 'error', 'message': 'analyzer not initialized',
       'code': 'INIT', 'startLine': 1, 'startColumn': 1,
       'endLine': 1, 'endColumn': 1, 'offset': 0, 'length': 0}
    ]);
  }
  _mem.modifyFile(_userFile, source);
  final ctx = _collection!.contextFor(_userFile);
  ctx.driver.changeFile(_userFile);
  await ctx.driver.applyPendingFileChanges();
  final result = await ctx.currentSession.getResolvedUnit(_userFile);
  if (result is! ResolvedUnitResult) {
    return jsonEncode([
      {'severity': 'error', 'message': 'resolution: $result',
       'code': 'INTERNAL', 'startLine': 1, 'startColumn': 1,
       'endLine': 1, 'endColumn': 1, 'offset': 0, 'length': 0}
    ]);
  }
  final LineInfo lineInfo = result.lineInfo;
  final List<Map<String, dynamic>> diagnostics = [];
  for (final d in result.errors) {
    final CharacterLocation loc = lineInfo.getLocation(d.offset);
    final CharacterLocation end =
        lineInfo.getLocation(d.offset + d.length);
    final String severity = switch (d.severity) {
      Severity.error => 'error',
      Severity.warning => 'warning',
      Severity.info => 'info',
    };
    diagnostics.add({
      'severity': severity,
      'message': d.message,
      'code': d.diagnosticCode.name,
      'startLine': loc.lineNumber,
      'startColumn': loc.columnNumber,
      'endLine': end.lineNumber,
      'endColumn': end.columnNumber,
      'offset': d.offset,
      'length': d.length,
    });
  }
  return jsonEncode(diagnostics);
}

@JS('dartAnalyzerInit')
external set _dartAnalyzerInit(JSFunction fn);

@JS('dartAnalyze')
external set _dartAnalyze(JSFunction fn);

void init(
    JSUint8Array bytes, JSArray<JSString> names, JSArray<JSUint8Array> sums) {
  final dartNames = <String>[for (final n in names.toDart) n.toDart];
  final dartSums = <Uint8List>[for (final s in sums.toDart) s.toDart];
  _init(bytes.toDart, dartNames, dartSums);
}

JSPromise<JSString> analyze(JSString source) {
  return (() async {
    try {
      final out = await _analyze(source.toDart);
      return out.toJS;
    } catch (e, st) {
      return jsonEncode([
        {'severity': 'error', 'message': 'analyzer threw: $e\n$st',
         'code': 'CRASH', 'startLine': 1, 'startColumn': 1,
         'endLine': 1, 'endColumn': 1, 'offset': 0, 'length': 0}
      ]).toJS;
    }
  })().toJS;
}

void main() {
  _dartAnalyzerInit = init.toJS;
  _dartAnalyze = analyze.toJS;
}
