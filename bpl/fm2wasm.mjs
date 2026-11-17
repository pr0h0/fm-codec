// Browser/Node/Bun host for the BPL-compiled fm2.wasm. Same API as js/fm2core.mjs.
//   const fm2 = await loadFm2Wasm(wasmBytesOrResponse);
//   fm2.encode(Uint8Array, { level, mode: 'bytes' | 'image', width }) -> Uint8Array
//   fm2.decode(Uint8Array) -> Uint8Array
export async function loadFm2Wasm(source) {
  const { instance } = source instanceof Response
    ? await WebAssembly.instantiateStreaming(source, {})
    : await WebAssembly.instantiate(source, {});
  const x = instance.exports;
  const mem = x.memory;
  if (x.__wasm_call_ctors) x.__wasm_call_ctors();

  // bump allocator never grows memory: grow it here before any call that may allocate
  const ensure = (L, mode) => {
    const top = x.malloc(0n) >>> 0;                       // current heap cursor
    const need = top + Number(x.fm2Estimate(BigInt(L), mode));
    const have = mem.buffer.byteLength;
    if (need > have) mem.grow(Math.ceil((need - have) / 65536));
  };
  const copyIn = (data, mode) => {
    ensure(data.length, mode);
    const p = x.fm2InputBuffer(BigInt(data.length)) >>> 0;
    new Uint8Array(mem.buffer, p, data.length).set(data);
    return p;
  };
  const copyOut = (n) => new Uint8Array(mem.buffer, x.fm2Result() >>> 0, n).slice();

  return {
    encode(data, { level = 3, mode = "bytes", width = 0 } = {}) {
      const m = mode === "image" ? 2 : 1;
      const p = copyIn(data, m);
      const n = Number(x.fm2Encode(level, m, BigInt(width), p, BigInt(data.length)));
      return copyOut(n);
    },
    decode(buf) {
      const L = buf.length >= 20 ? new DataView(buf.buffer, buf.byteOffset).getUint32(12, true) : 0;
      const m = buf[4] === 2 ? 2 : 1;
      ensure(Math.max(L, buf.length), m);
      const p = x.fm2InputBuffer(BigInt(buf.length)) >>> 0;
      new Uint8Array(mem.buffer, p, buf.length).set(buf);
      const n = Number(x.fm2Decode(p, BigInt(buf.length)));
      if (n < 0) throw new Error("not an FM2 file");
      return copyOut(n);
    },
  };
}
