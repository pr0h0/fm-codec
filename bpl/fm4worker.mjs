// Web Worker for createFm4() in fm4wasm.mjs: one fm4.wasm instance, one job at a time. Its buffers
// are kept and reused by the next job.
import { loadFm4Wasm } from "./fm4wasm.mjs";
let fm4 = null, ready = null, mod = null;
self.onmessage = async (e) => {
  const { module, op, data, opts } = e.data;
  if (module) { mod = module; ready = loadFm4Wasm(module); return; }
  try {
    fm4 ||= await ready;
    const out = op === "enc" ? fm4.encode(data, opts) : fm4.decode(data);
    self.postMessage({ out }, [out.buffer]);
  } catch (err) {
    fm4 = null; ready = loadFm4Wasm(mod);   // a trap (corrupt input) may leave the instance half-updated
    self.postMessage({ error: String(err && err.message || err) });
  }
};
