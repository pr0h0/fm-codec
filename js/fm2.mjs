// FM2 CLI for Bun and Node. Same CLI and byte-identical output as c/fm2.
//   fm2.mjs enc LEVEL bytes IN OUT | enc LEVEL image WIDTH IN OUT | dec IN OUT
import { readFileSync, writeFileSync } from "node:fs";
import { encode, decode } from "./fm2core.mjs";

const usage = () => {
  console.error("usage: fm2 enc LEVEL(0-5) bytes IN OUT | fm2 enc LEVEL image WIDTH IN OUT | fm2 dec IN OUT");
  process.exit(2);
};
const a = process.argv.slice(2);
const read = (p) => { const b = readFileSync(p); return new Uint8Array(b.buffer, b.byteOffset, b.length); };
if (a.length >= 5 && a[0] === "enc") {
  const level = parseInt(a[1], 10), image = a[2] === "image";
  if (!(level >= 0 && level <= 5) || (image && a.length < 6)) usage();
  const width = image ? parseInt(a[3], 10) : 0;
  const data = read(a[image ? 4 : 3]);
  if (image && (!(width > 0) || data.length % (3 * width))) { console.error("bad width"); process.exit(1); }
  writeFileSync(a[image ? 5 : 4], encode(data, { level, mode: image ? "image" : "bytes", width }));
} else if (a.length === 3 && a[0] === "dec") {
  let d;
  try { d = decode(read(a[1])); } catch (e) { console.error(e.message); process.exit(1); }
  writeFileSync(a[2], d);
} else usage();
