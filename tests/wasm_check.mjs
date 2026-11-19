// node tests/wasm_check.mjs BPLDIR LIST: each line "input c_output level mode [args]"; the wasm build must
// produce c_output exactly and decode it back to input. Exit status 1 on any mismatch.
import { readFileSync } from "node:fs";
const [dir, list] = process.argv.slice(2);
const { loadFm4Wasm } = await import(`${dir}/fm4wasm.mjs`);
const fm4 = await loadFm4Wasm(readFileSync(`${dir}/fm4.wasm`));
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
let bad = 0;
for (const line of readFileSync(list, "utf8").trim().split("\n")) {
  const [inp, ref, level, mode, a, b] = line.split(" ");
  const data = new Uint8Array(readFileSync(inp)), want = new Uint8Array(readFileSync(ref));
  const opts = { level: +level, mode, width: +a || 0, height: +b || 0, channels: +a || 1 };
  if (!eq(fm4.encode(data, opts), want)) { console.log(`FAIL: wasm output differs from C: ${level} ${mode} ${inp}`); bad = 1; }
  if (!eq(fm4.decode(want), data)) { console.log(`FAIL: wasm decode ${level} ${mode} ${inp}`); bad = 1; }
}
process.exit(bad);
