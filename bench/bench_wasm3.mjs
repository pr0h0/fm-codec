// fm3: JS port vs BPL->WebAssembly, in the current runtime (node or bun). Verifies byte-identity with C.
//   node bench/bench_wasm.mjs   |   bun bench/bench_wasm.mjs
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import * as js from "../js/fm3core.mjs";
import { loadFm3Wasm } from "../bpl/fm3wasm.mjs";

const root = new URL("..", import.meta.url).pathname;
const wasm = await loadFm3Wasm(readFileSync(root + "bpl/fm3.wasm"));
const runtime = typeof Bun !== "undefined" ? `bun ${Bun.version}` : `node ${process.version}`;
const sets = [
  ["text_1mb", "bytes", 0, "testdata/text_1mb.bin"],
  ["noah", "image", 320, "testdata/thumbref_noah.rgb"],
  ["library", "image", 512, "testdata/style_win_library.rgb"],
  ["A_original", "image", 2048, "testdata/thumbnail-A-original.rgb"],
];
const levels = (process.env.LEVELS || "1,3,4").split(",").map(Number);
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const time = (f) => { const t = performance.now(); const r = f(); return [r, (performance.now() - t) / 1000]; };

console.log(`runtime: ${runtime}`);
console.log("data        lvl   ratio   js_enc  js_dec  wasm_enc wasm_dec   MB/s js / wasm (enc)   check");
for (const [name, mode, width, path] of sets) {
  const data = new Uint8Array(readFileSync(root + path));
  for (const level of levels) {
    const args = mode === "image" ? ["enc", String(level), "image", String(width)] : ["enc", String(level), "bytes"];
    const cOut = root + `out_c_${name}_${level}.fm3`;
    execFileSync(root + "c/fm3", [...args, root + path, cOut]);
    const cBytes = new Uint8Array(readFileSync(cOut));
    const [je, jet] = time(() => js.encode(data, { level, mode, width }));
    const [jd, jdt] = time(() => js.decode(je));
    const [we, wet] = time(() => wasm.encode(data, { level, mode, width }));
    const [wd, wdt] = time(() => wasm.decode(we));
    const ok = eq(je, cBytes) && eq(we, cBytes) && eq(jd, data) && eq(wd, data);
    const mb = data.length / 1e6;
    console.log(`${name.padEnd(11)} L${level}  ${(we.length / data.length).toFixed(4)}  ${jet.toFixed(2).padStart(6)}  ${jdt.toFixed(2).padStart(6)}  ${wet.toFixed(2).padStart(8)} ${wdt.toFixed(2).padStart(8)}   ${(mb / jet).toFixed(2).padStart(6)} / ${(mb / wet).toFixed(2).padEnd(6)}        ${ok ? "identical+roundtrip" : "MISMATCH"}`);
    execFileSync("rm", ["-f", cOut]);
  }
}
