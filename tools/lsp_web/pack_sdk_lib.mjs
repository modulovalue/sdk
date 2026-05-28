// Pack sdk/lib/ into a single binary blob the wasm can mount.
// Format:
//   magic    : 4 bytes "DRTM"
//   nEntries : u32 LE
//   for each entry:
//     pathLen : u32 LE
//     pathBytes
//     contentLen : u32 LE
//     contentBytes
import { promises as fs } from "node:fs";
import { join, relative, sep } from "node:path";

const root = process.argv[2];
const out  = process.argv[3];
if (!root || !out) {
  console.error("usage: node pack_sdk_lib.mjs <sdk-lib-dir> <out-file>");
  process.exit(2);
}

const entries = [];
async function walk(dir) {
  for (const e of await fs.readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await walk(p);
    else if (e.isFile()) entries.push(p);
  }
}
await walk(root);
entries.sort();

const buffers = [];
const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32LE(n, 0); return b; };
buffers.push(Buffer.from("DRTM"));
buffers.push(u32(entries.length));

for (const abs of entries) {
  const rel = relative(root, abs).split(sep).join("/");
  const pathBytes = Buffer.from(rel, "utf-8");
  const content = await fs.readFile(abs);
  buffers.push(u32(pathBytes.length));
  buffers.push(pathBytes);
  buffers.push(u32(content.length));
  buffers.push(content);
}

const blob = Buffer.concat(buffers);
await fs.writeFile(out, blob);
console.log(`packed ${entries.length} files into ${out} (${blob.length} bytes)`);
