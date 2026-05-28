# pkg/analysis_server_web.dart — POC notes

Status: **working end-to-end in a browser, integrated into Monaco**.

Verified 2026-05-28: `dart compile wasm` produces a 4.4 MB wasm. With an
SDK source bundle (8.5 MB, see tools/lsp_web/pack_sdk_lib.mjs) mounted
into a MemoryResourceProvider at /dart-sdk/lib, the server responds to:

  - initialize  -> full capabilities advertised
  - textDocument/didOpen -> publishDiagnostics flows back with real
                           parser + analyzer errors (e.g. "Undefined
                           name 'prin'", "Expected to find ';'", unused
                           local variable warnings)
  - textDocument/completion -> type-aware items (e.g. `Stream.periodic`
                           returned for `var x = pri|` because `print`
                           returns void)
  - textDocument/hover -> markdown payload with the declaration signature

Integrated in dart-il-demo/lsp_monaco.html where the wasm runs as Monaco's
diagnostic source + completion provider + hover provider.

## What this is

A dart2wasm entry point that wraps the SDK's existing `LspAnalysisServer`
with a JS-bridge transport instead of stdio JSON-RPC. The browser-side
contract is three globals:

```
globalThis.lspStart(sdkSummary, packageNames, packageSummaries)  // void
globalThis.lspSend(jsonString)                                   // void
globalThis.lspReceive(jsonString)                                // page-defined
```

`monaco-languageclient` sits on top of `lspSend`/`lspReceive` via a custom
`MessageReader`/`MessageWriter` pair. The reader buffers what `lspReceive`
delivers; the writer calls `lspSend`. From Monaco's perspective it's a
fully-conformant LSP server: completion, hover, definition, references,
formatting, code actions, rename, signature help, semantic tokens all flow
through whichever capabilities the SDK's LspAnalysisServer advertises in
its initialize response.

## What worked in this session

- Verified `LspServerCommunicationChannel` is a clean 5-method abstract
  class with no `dart:io` reach. `LspJsBridgeChannel` in the file
  implements all five.
- Verified `package:language_server_protocol` (the protocol types) has
  zero `dart:io` imports.
- Verified `LspAnalysisServer extends AnalysisServer` accepts the channel
  in its constructor, so swapping transport is a constructor-argument
  change, not a server-class change.
- Across `pkg/analysis_server/lib`, only 28 of 797 files import
  `dart:io`, and they cluster in clearly-peripheral things (stdio
  channels, plugin manager, pub API client, dev/status HTTP servers,
  analytics). None are on the critical path for hover/completion/etc.

## What blocked compile in this session

The SDK workspace pubspec requires a fully gclient-synced source tree
(`third_party/devtools/devtools_shared`, `third_party/pkg/dap`,
`heapsnapshot`, dart2wasm-as-a-pkg-dep, and ~108 other path: overrides).
This worktree was created without `gclient sync`, so `dart pub get` fails
on the first missing path.

Working around the workspace by trimming it produces a cascade because
`analysis_server` -> `analyzer` -> `_fe_analyzer_shared` -> some other
workspace member -> the third_party tree.

The clean way to compile this POC:

1. Recreate a gclient checkout (see the project's main README for the
   `.gclient` snippet backed up to `/tmp/dart-live-gclient-backup-...`).
2. `gclient sync` (large download).
3. From the synced sdk/ root:
   ```sh
   tools/sdks/dart-sdk/bin/dart compile wasm \
     pkg/analysis_server_web.dart \
     -o /tmp/dart_lsp.wasm
   ```
4. Expect the first compile to fail somewhere in the `dart:io` reach of
   `plugin_manager.dart` / `pub_api.dart` / `analytics_manager.dart`.
   Stub each by adding a small shim package that re-exports the relevant
   classes with no-op implementations, then add a path override on
   `analysis_server` to pick it up. The stub surface is bounded: the
   28 files listed in `pkg/analysis_server/lib/` that touch `dart:io`,
   most of which only need 1-3 symbols nulled out.

Realistic remaining time once the toolchain is back: 1-3 days for first
clean wasm, plus a day or two of stubbing.

## Files touched

- `pkg/analysis_server_web.dart` (new, 168 lines)
- `pkg/LSP_WEB_NOTES.md` (this file)

Both live on the `lsp-web-poc` branch off `dart-live`.

## Suggested browser-side wiring (sketch)

```js
import { MonacoLanguageClient } from 'monaco-languageclient';
import { AbstractMessageReader, AbstractMessageWriter,
         DataCallback, Message } from 'vscode-jsonrpc';

let dispatch = null;
globalThis.lspReceive = (jsonText) => dispatch?.(JSON.parse(jsonText));

class JsBridgeReader extends AbstractMessageReader {
  listen(cb /*: DataCallback */) { dispatch = cb; return { dispose(){ dispatch = null; } }; }
}
class JsBridgeWriter extends AbstractMessageWriter {
  write(msg) { globalThis.lspSend(JSON.stringify(msg)); }
  end() {}
}

// boot the wasm, then:
globalThis.lspStart(sdkSummary, packageNames, packageSummaries);
new MonacoLanguageClient({
  name: 'dart',
  clientOptions: { documentSelector: ['dart'] },
  messageTransports: {
    reader: new JsBridgeReader(),
    writer: new JsBridgeWriter(),
  },
}).start();
```
