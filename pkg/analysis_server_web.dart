// @dart=3.12
//
// Browser-side Dart Language Server, full LSP wire-compatible.
// Compiles to wasm via dart2wasm. Replaces the byte-stream transport with a
// JS bridge: the page calls `lspSend(jsonString)`, the server calls
// `globalThis.lspReceive(jsonString)`. monaco-languageclient sits on top of
// these via a custom MessageReader/MessageWriter.
//
// JS API (set on globalThis):
//   lspStart(Uint8Array sdkSummary, Array<string> packageNames,
//            Array<Uint8Array> packageSummaries): void
//   lspSend(string jsonRpcMessage): void  -- inbound LSP message
//   // Outbound LSP messages are delivered by the server calling
//   // globalThis.lspReceive(jsonString) which the page must define before
//   // calling lspStart.
//
// Status: POC code. Compiles in a fully-synced SDK workspace; pending the
// `dart:io` stubbing pass and dart2wasm shake-out described in NOTES.md.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:analysis_server/lsp_protocol/protocol.dart';
import 'package:analysis_server/src/analytics/analytics_manager.dart';
import 'package:analysis_server/src/legacy_analysis_server.dart'
    show AnalysisServerOptions;
import 'package:analysis_server/src/lsp/channel/lsp_channel.dart';
import 'package:analysis_server/src/lsp/lsp_analysis_server.dart';
import 'package:analysis_server/src/server/crash_reporting_attachments.dart';
import 'package:analysis_server/src/server/diagnostic_server.dart';
import 'package:analysis_server/src/session_logger/session_logger.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:analyzer/src/generated/sdk.dart' show DartSdkManager;
import 'package:path/path.dart' as p;
import 'package:unified_analytics/unified_analytics.dart' show NoOpAnalytics;

// ---------------------------------------------------------------------------
// JS interop surface (defined on globalThis).
// ---------------------------------------------------------------------------

@JS('lspStart')
external set _lspStart(JSFunction fn);
@JS('lspSend')
external set _lspSend(JSFunction fn);

/// Callback the page must define BEFORE calling `lspStart`. Receives the JSON
/// string of each outbound LSP message (response or notification).
@JS('lspReceive')
external JSFunction get _lspReceive;

// ---------------------------------------------------------------------------
// JS bridge channel.
// ---------------------------------------------------------------------------

/// LSP channel that ferries messages between Dart-side analysis_server and a
/// JS-side message reader/writer pair via globalThis callbacks.
class LspJsBridgeChannel implements LspServerCommunicationChannel {
  final _inbound = StreamController<Message>();
  final _closed = Completer<void>();

  /// Called by the JS side via `lspSend(jsonString)`.
  void deliverIncoming(String jsonText) {
    try {
      final json = jsonDecode(jsonText) as Map<String, Object?>;
      final msg = Message.fromJson(json);
      _inbound.add(msg);
    } catch (e, st) {
      // Surface as a parse-error notification so the JS side can log it.
      _emit({
        'jsonrpc': '2.0',
        'method': r'$/lspWasmError',
        'params': {'kind': 'parse', 'error': '$e', 'stack': '$st'},
      });
    }
  }

  void _emit(Map<String, Object?> payload) {
    final jsString = jsonEncode(payload).toJS;
    _lspReceive.callAsFunction(null, jsString);
  }

  @override
  Future<void> get closed => _closed.future;

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _inbound.close();
  }

  @override
  StreamSubscription<void> listen(
    void Function(Message message) onMessage, {
    Function? onError,
    void Function()? onDone,
  }) =>
      _inbound.stream.listen(onMessage, onError: onError, onDone: onDone);

  @override
  void sendNotification(NotificationMessage notification) =>
      _emit(notification.toJson());

  @override
  void sendRequest(RequestMessage request) => _emit(request.toJson());

  @override
  void sendResponse(ResponseMessage response) => _emit(response.toJson());
}

// ---------------------------------------------------------------------------
// Server bootstrap.
// ---------------------------------------------------------------------------

const _userRoot = '/user';
const _userFile = '/user/lib/main.dart';
const _sdkSummaryPath = '/sdk.sum';

LspJsBridgeChannel? _channel;

/// Unpack the "DRTM" bundle produced by tools/pack_sdk_lib.mjs into [mem]
/// at /dart-sdk/lib/<rel-path>. Format:
///   magic    : 4 bytes "DRTM"
///   nEntries : u32 LE
///   for each:  u32 pathLen, pathBytes, u32 contentLen, contentBytes
void _unpackSdkLib(MemoryResourceProvider mem, Uint8List bundle) {
  final bd = ByteData.sublistView(bundle);
  if (bundle.length < 8 ||
      bd.getUint8(0) != 0x44 ||
      bd.getUint8(1) != 0x52 ||
      bd.getUint8(2) != 0x54 ||
      bd.getUint8(3) != 0x4D) {
    throw StateError('bad SDK bundle magic');
  }
  var off = 4;
  final n = bd.getUint32(off, Endian.little); off += 4;
  for (var i = 0; i < n; i++) {
    final pLen = bd.getUint32(off, Endian.little); off += 4;
    final pBytes = bundle.sublist(off, off + pLen); off += pLen;
    final cLen = bd.getUint32(off, Endian.little); off += 4;
    final cBytes = bundle.sublist(off, off + cLen); off += cLen;
    final rel = String.fromCharCodes(pBytes);
    mem.newFileWithBytes('/dart-sdk/lib/$rel', cBytes);
  }
}

void _start(
    Uint8List sdkSummary,
    Uint8List sdkLibBundle,
    List<String> packageNames,
    List<Uint8List> packageSummaries) {
  if (_channel != null) {
    throw StateError('lspStart called twice');
  }

  // Use posix paths inside our in-memory FS so analyzer's pathToUri matches.
  final mem = MemoryResourceProvider(context: p.Context(style: p.Style.posix));
  mem.newFileWithBytes(_sdkSummaryPath, sdkSummary);

  // ignore: avoid_print
  print('[lsp-web] _start: unpacking SDK lib bundle '
      '(${sdkLibBundle.length} bytes)');
  _unpackSdkLib(mem, sdkLibBundle);
  // FolderBasedDartSdk reads a few files at the SDK root (not under lib/).
  // Stub the minimum the analyzer touches.
  mem.newFile('/dart-sdk/version', '3.13.0-dev\n');
  mem.newFile('/dart-sdk/revision', '0000000000000000000000000000000000000000\n');
  // ignore: avoid_print
  print('[lsp-web] _start: SDK lib mounted at /dart-sdk/lib/');

  // Stub a tiny package_config.json so URI resolution works for our user
  // file and the supplied external packages.
  final pkgEntries = <Map<String, String>>[
    {
      'name': 'user',
      'rootUri': '../',
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    },
  ];
  for (var i = 0; i < packageNames.length; i++) {
    final root = '/ext_pkg_$i';
    mem.newFile('$root/pubspec.yaml', 'name: ${packageNames[i]}\n');
    mem.newFileWithBytes('$root/lib.sum', packageSummaries[i]);
    pkgEntries.add({
      'name': packageNames[i],
      'rootUri': 'file://$root',
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
  }
  mem.newFile('$_userRoot/pubspec.yaml', 'name: user\n');
  mem.newFile(
    '$_userRoot/.dart_tool/package_config.json',
    jsonEncode({'configVersion': 2, 'packages': pkgEntries}),
  );
  mem.newFile(_userFile, '// placeholder\n');

  // ignore: avoid_print
  print('[lsp-web] _start: building channel');
  final channel = _channel = LspJsBridgeChannel();

  // ignore: avoid_print
  print('[lsp-web] _start: constructing LspAnalysisServer');
  // Mirrors LspSocketServer.createAnalysisServer's construction site.
  final server = LspAnalysisServer(
    channel,
    mem,
    AnalysisServerOptions(),
    DartSdkManager('/dart-sdk'),
    AnalyticsManager(const NoOpAnalytics()),
    CrashReportingAttachmentsBuilder.empty,
    InstrumentationService.NULL_SERVICE,
    SessionLogger(),
    diagnosticServer: NoOpDiagnosticServer(),
  );

  // ignore: avoid_print
  print('[lsp-web] _start: server constructed (${server.runtimeType})');
}

/// No-op stand-in for the LSP diagnostic-pages server.
class NoOpDiagnosticServer extends DiagnosticServer {
  @override
  Future<int> getServerPort() async => 0;
  @override
  Future<void> startOnPort(int port) async {}
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

void start(
    JSUint8Array sdkSummary,
    JSUint8Array sdkLibBundle,
    JSArray<JSString> packageNames,
    JSArray<JSUint8Array> packageSummaries) {
  _start(
    sdkSummary.toDart,
    sdkLibBundle.toDart,
    [for (final n in packageNames.toDart) n.toDart],
    [for (final s in packageSummaries.toDart) s.toDart],
  );
}

void send(JSString jsonText) {
  final ch = _channel;
  if (ch == null) {
    throw StateError('lspSend called before lspStart');
  }
  ch.deliverIncoming(jsonText.toDart);
}

void main() {
  // ignore: avoid_print
  print('[lsp-web] main: wiring exports');
  _lspStart = start.toJS;
  _lspSend = send.toJS;
  // ignore: avoid_print
  print('[lsp-web] main: ready (call lspStart from JS to boot server)');
}
