// Browser/Node/Bun host for the BPL-compiled fm4.wasm (same API shape as fm3wasm.mjs).
//   const fm4 = await loadFm4Wasm(wasmBytesOrResponse);
//   fm4.encode(Uint8Array, { level, mode: 'bytes' | 'image', width }) -> Uint8Array
//   fm4.decode(Uint8Array) -> Uint8Array
export async function loadFm4Wasm(source) {
  const { instance } = source instanceof Response
    ? await WebAssembly.instantiateStreaming(source, {})
    : await WebAssembly.instantiate(source, {});
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
    encode(data, { level = 3, mode = "bytes", width = 0 } = {}) {
      const m = mode === "image" ? 2 : 1;
      const p = copyIn(data, m);
      const n = Number(x.fm4Encode(level, m, BigInt(width), p, BigInt(data.length)));
      return copyOut(n);
    },
    decode(buf) {
      const L = buf.length >= 28 ? new DataView(buf.buffer, buf.byteOffset).getUint32(16, true) : 0;
      const m = buf[4] === 2 ? 2 : 1;
      ensure(Math.max(L, buf.length), m);
      const p = x.fm4InputBuffer(BigInt(buf.length)) >>> 0;
      new Uint8Array(mem.buffer, p, buf.length).set(buf);
      const n = Number(x.fm4Decode(p, BigInt(buf.length)));
      if (n < 0) throw new Error("not an FM4 file");
      return copyOut(n);
    },
  };
}
