// Browser/Node/Bun host for the BPL-compiled fm4.wasm (same API shape as fm3wasm.mjs).
//   const fm4 = await loadFm4Wasm(wasmBytesOrResponse);
//   fm4.encode(Uint8Array, { level, mode: 'bytes' | 'image', width }) -> Uint8Array
//   fm4.encode(pcm16le, { level, mode: 'audio', channels }), fm4.encode(rgbFrames, { level, mode: 'video', width, height })
//   fm4.decode(Uint8Array) -> Uint8Array
// source: bytes, a fetch() Response, or a compiled WebAssembly.Module. This API is synchronous and runs on
// the calling thread; in a page use createFm4() below, which works in Web Workers and in parallel.
export async function loadFm4Wasm(source) {
  const r = source instanceof WebAssembly.Module ? await WebAssembly.instantiate(source, {})
    : typeof Response !== "undefined" && source instanceof Response ? await WebAssembly.instantiateStreaming(source, {})
    : await WebAssembly.instantiate(source, {});
  const instance = r.instance || r;
  const x = instance.exports;
  const mem = x.memory;
  if (x.__wasm_call_ctors) x.__wasm_call_ctors();

  // bump allocator never grows memory: grow it here before any call that may allocate
  const ensure = (L, mode) => {
    const top = x.malloc(0n) >>> 0;                       // current heap cursor
    const need = top + Number(x.fm4Estimate(BigInt(L), mode));
    const have = mem.buffer.byteLength;
    if (need > have) mem.grow(Math.ceil((need - have) / 65536));
  };
  const copyIn = (data, mode) => {
    ensure(data.length, mode);
    const p = x.fm4InputBuffer(BigInt(data.length)) >>> 0;
    new Uint8Array(mem.buffer, p, data.length).set(data);
    return p;
  };
  const copyOut = (n) => new Uint8Array(mem.buffer, x.fm4Result() >>> 0, n).slice();

  return {
    encode(data, { level = 3, mode = "bytes", width = 0, height = 0, channels = 1 } = {}) {
      const m = mode === "image" || mode === "video" ? 2 : mode === "audio" ? 3 : 1;
      let w = width;
      if (m === 2 && (!(width > 0) || data.length % (3 * width))) throw new Error("bad width");
      if (mode === "video") {
        if (width > 65535 || !(height > 0) || height > 65535 || data.length % (3 * width * height)) throw new Error("video: bad frame size");
        w = width + height * 65536;
      }
      if (m === 3) {
        if (!(channels >= 1 && channels <= 8) || data.length % (2 * channels)) throw new Error("audio: need 1-8 channels and a whole number of 16-bit frames");
        w = channels;
      }
      const p = copyIn(data, m);
      const n = Number(x.fm4Encode(level, m, BigInt(w), p, BigInt(data.length)));
      return copyOut(n);
    },
    decode(buf) {
      const L = buf.length >= 28 ? new DataView(buf.buffer, buf.byteOffset).getUint32(16, true) : 0;
      const m = buf[4];
      ensure(Math.max(L, buf.length), m);
      const p = x.fm4InputBuffer(BigInt(buf.length)) >>> 0;
      new Uint8Array(mem.buffer, p, buf.length).set(buf);
      const n = Number(x.fm4Decode(p, BigInt(buf.length)));
      if (n < 0) throw new Error("not an FM4 file");
      return copyOut(n);
    },
  };
}

// CRC-32 (IEEE) and the per-stream check before a segment's length is added up and allocated (stream_ok in c/fm4.c)
const CRC_T = Uint32Array.from({ length: 256 }, (_, i) => { let c = i; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (u8) => { let c = 0xFFFFFFFF; for (const b of u8) c = CRC_T[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const streamOk = (s, L) => {
  if (L > 2 ** 40) return false;
  if (s[3] !== 2) return true;
  if (s.length < 36 || new DataView(s.buffer, s.byteOffset).getUint32(32, true) !== crc32(s.subarray(0, 32))) return false;
  return s[4] === 0 ? L <= s.length - 36 : Math.floor(L / 4096) <= s.length - 36;
};

// ---- browser API: Web Worker pool and segmented video (FMV, same format and cut as c/fm4.c) ----
//   const fm4 = await createFm4(new URL("fm4.wasm", import.meta.url), { threads: 4 });
//   const packed = await fm4.encode(data, { level, mode, width, height, channels });   // Promise<Uint8Array>
//   const data = await fm4.decode(packed);  fm4.terminate();
// All coding runs in workers (bpl/fm4worker.mjs), so the page stays responsive. Video of at least
// 2 x segMB (default 64 MB) is cut into L / segMB runs of whole frames ("FMV\x01" | u32 n | n x (u64 len |
// FM4 stream)), coded one segment per worker; the file is the same for any thread count. Each worker
// needs about 500 MB for a 64 MB video segment (600-800 MB for text). Without Worker (Node) it runs
// inline, one segment after another.
export async function createFm4(source, { threads, workerUrl = new URL("./fm4worker.mjs", import.meta.url) } = {}) {
  if (typeof source === "string" || source instanceof URL) source = await fetch(source);
  const module = source instanceof WebAssembly.Module ? source
    : typeof Response !== "undefined" && source instanceof Response ? await WebAssembly.compileStreaming(source)
    : await WebAssembly.compile(source);
  const hw = (typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 4;
  const max = Math.max(1, threads || Math.min(hw, 4));
  const useWorkers = typeof Worker !== "undefined";
  let inline = null;
  const idle = [], all = [], queue = [];
  let seq = 0;
  const pump = () => {
    while (queue.length && (idle.length || all.length < max)) {
      let w = idle.pop();
      if (!w) {
        w = new Worker(workerUrl, { type: "module" });
        w.postMessage({ module });
        w.onmessage = (e) => { const j = w.job; w.job = null; idle.push(w); e.data.error ? j.reject(new Error(e.data.error)) : j.resolve(e.data.out); pump(); };
        w.onerror = (e) => { e.preventDefault?.(); const j = w.job; w.job = null; w.terminate(); all.splice(all.indexOf(w), 1); j?.reject(new Error(e.message || "fm4 worker failed")); pump(); };
        all.push(w);
      }
      const j = queue.shift();
      w.job = j;
      w.postMessage({ id: seq++, op: j.op, data: j.data, opts: j.opts }, [j.data.buffer]);
    }
  };
  // data must own its buffer (it is transferred to the worker)
  const run = async (op, data, opts) => {
    if (!useWorkers) {
      inline ||= await loadFm4Wasm(module);
      return op === "enc" ? inline.encode(data, opts) : inline.decode(data);
    }
    return new Promise((resolve, reject) => { queue.push({ op, data, opts, resolve, reject }); pump(); });
  };
  const own = (u8, a = 0, b = u8.length) => u8.slice(a, b);

  return {
    async encode(data, opts = {}) {
      const { mode = "bytes", width = 0, height = 0, segMB = 64 } = opts;
      const fb = 3 * width * height;
      if (mode === "video" && fb > 0 && data.length % fb === 0) {
        const L = data.length, nf = L / fb, seg = segMB * 1048576;
        let ns = seg > 0 ? Math.floor(L / seg) : 1;
        ns = ns > nf ? Math.max(nf, 1) : Math.max(ns, 1);
        if (ns > 1) {
          const parts = await Promise.all(Array.from({ length: ns }, (_, k) =>
            run("enc", own(data, Math.floor(nf * k / ns) * fb, Math.floor(nf * (k + 1) / ns) * fb), opts)));
          const out = new Uint8Array(8 + parts.reduce((t, p) => t + 8 + p.length, 0));
          const dv = new DataView(out.buffer);
          out.set([70, 77, 86, 1]); dv.setUint32(4, ns, true);
          let pos = 8;
          for (const p of parts) { dv.setBigUint64(pos, BigInt(p.length), true); out.set(p, pos + 8); pos += 8 + p.length; }
          return out;
        }
      }
      return run("enc", own(data), opts);
    },
    async decode(buf) {
      const n = buf.length;
      if (!(n >= 8 && buf[0] === 70 && buf[1] === 77 && buf[2] === 86 && buf[3] === 1)) return run("dec", own(buf));
      const dv = new DataView(buf.buffer, buf.byteOffset, n), ns = dv.getUint32(4, true), segs = [];
      let pos = 8, all = 0;
      for (let k = 0; k < ns; k++) {
        if (n - pos < 36) throw new Error("not an FM4 file, or corrupt");
        const m = Number(dv.getBigUint64(pos, true)), L = Number(dv.getBigUint64(pos + 24, true));
        if (m < 28 || m > n - pos - 8 || !streamOk(buf.subarray(pos + 8, pos + 8 + m), L)) throw new Error("not an FM4 file, or corrupt");
        segs.push([pos + 8, m, L]); all += L; pos += 8 + m;
      }
      if (pos !== n) throw new Error("not an FM4 file, or corrupt");
      const out = new Uint8Array(all);
      let o = 0;
      await Promise.all(segs.map(([p, m, L]) => {
        const at = o; o += L;
        return run("dec", own(buf, p, p + m)).then((d) => { if (d.length !== L) throw new Error("not an FM4 file, or corrupt"); out.set(d, at); });
      }));
      return out;
    },
    terminate() { for (const w of all) w.terminate(); all.length = 0; idle.length = 0; },
  };
}
