import { readFileSync, writeFileSync } from "node:fs";
import { loadFm4Wasm } from "/home/pr0h0/Projects/fm-codec/bpl/fm4wasm.mjs";
const [inp, out, mode, a, b] = process.argv.slice(2);
const fm4 = await loadFm4Wasm(readFileSync("/home/pr0h0/Projects/fm-codec/bpl/fm4.wasm"));
writeFileSync(out, fm4.encode(new Uint8Array(readFileSync(inp)), { level: 4, mode, width: +a || 0, height: +b || 0, channels: +a || 1 }));
