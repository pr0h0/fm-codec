// Model fraction (FRC1), JavaScript port for Bun and Node. Same spec as c/fm.c
// (byte-identical output).
//   bun fm.mjs enc bytes IN OUT | enc image WIDTH IN OUT | dec IN OUT
import { readFileSync, writeFileSync } from "node:fs";

const TBITS = 22, TSIZE = 1 << TBITS, TMASK = TSIZE - 1;
const SQ_T = [1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
  2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094];
const squash = (d) => {
  if (d > 2047) return 4095;
  if (d < -2047) return 1;
  const w = d & 127, i = (d >> 7) + 16;
  return (SQ_T[i] * (128 - w) + SQ_T[i + 1] * w + 64) >> 7;
};
const STRETCH = new Int32Array(4096);
{
  let pi = 0;
  for (let x = -2047; x <= 2047; x++) {
    const v = squash(x);
    for (let j = pi; j <= v; j++) STRETCH[j] = x;
    pi = v + 1;
  }
  for (let j = pi; j < 4096; j++) STRETCH[j] = 2047;
}
const RECIP = Int32Array.from({ length: 64 }, (_, n) => Math.floor(65536 / (2 * n + 3)));

const H = (k, a, b, c) => {
  let h = Math.imul(k + 1, 0x9e3779b1);
  h = Math.imul(h ^ a, 0x85ebca6b); h ^= h >>> 13;
  h = Math.imul(h ^ b, 0xc2b2ae35); h ^= h >>> 16;
  h = Math.imul(h ^ c, 0x85ebca6b); h ^= h >>> 15;
  return h >>> 0;
};

function makeCoder(input) {
  // input == null -> encoder; else decoder over input bytes
  const c = { x1: 0, x2: 0xffffffff, x: 0, pos: 0, out: new Uint8Array(1 << 16), len: 0 };
  if (input) for (let i = 0; i < 4; i++) c.x = ((c.x << 8) | (c.pos < input.length ? input[c.pos] : 0)) >>> 0, c.pos++;
  c.bit = (p12, bit) => {
    const xmid = c.x1 + ((c.x2 - c.x1) >>> 12) * p12;
    if (input) bit = c.x <= xmid ? 1 : 0;
    if (bit) c.x2 = xmid; else c.x1 = xmid + 1;
    while (((c.x1 ^ c.x2) & 0xff000000) === 0) {
      if (input) {
        c.x = ((c.x << 8) | (c.pos < input.length ? input[c.pos] : 0)) >>> 0;
        c.pos++;
      } else {
        if (c.len === c.out.length) { const n = new Uint8Array(c.len * 2); n.set(c.out); c.out = n; }
        c.out[c.len++] = c.x2 >>> 24;
      }
      c.x1 = (c.x1 << 8) >>> 0;
      c.x2 = ((c.x2 << 8) | 255) >>> 0;
    }
    return bit;
  };
  return c;
}

function run(coder, mode, width, data, L, decoding) {
  const nin = mode ? 7 : 6;
  const P = [], N = [];
  for (let k = 0; k < nin; k++) { P.push(new Uint16Array(TSIZE).fill(32768)); N.push(new Uint8Array(TSIZE)); }
  const W = Array.from({ length: 8 }, () => new Int32Array(nin).fill(19661));
  const err = mode ? new Int16Array(Math.max(L, 1)) : null;
  const ORD = [0, 1, 2, 3, 4, 6];
  const ctx = new Uint32Array(nin), idx = new Uint32Array(nin), st = new Int32Array(nin);
  const Q = (e) => (e < -12 ? -12 : e > 12 ? 12 : e) + 16;
  let c4 = 0, c8 = 0;

  for (let i = 0; i < L; i++) {
    let med = 0;
    if (mode === 0) {
      for (let k = 0; k < 6; k++) {
        const o = ORD[k];
        const m = o >= 4 ? 0xffffffff : (1 << (8 * o)) - 1;
        ctx[k] = H(o, (c4 & m) >>> 0, o === 6 ? c8 & 0xffff : 0, 0);
      }
    } else {
      const ch = i % 3, x = Math.floor(i / 3) % width, up = i - 3 * width;
      const a = x ? data[i - 3] : up >= 0 ? data[up] : 0;
      const b = up >= 0 ? data[up] : a;
      const cc = up >= 0 && x ? data[up - 3] : b;
      const mx = a > b ? a : b, mn = a < b ? a : b;
      med = cc >= mx ? mn : cc <= mn ? mx : a + b - cc;
      const ea = x ? Q(err[i - 3]) : 16, eb = up >= 0 ? Q(err[up]) : 16, ep = ch ? Q(err[i - 1]) : 255;
      const gv = Math.abs(a - cc) + Math.abs(b - cc);
      const g = 32 - Math.clz32(gv);
      ctx[0] = H(10, ch, 0, 0); ctx[1] = H(11, ch, ea, 0); ctx[2] = H(12, ch, eb, 0);
      ctx[3] = H(13, ch, ep, 0); ctx[4] = H(14, ch, ea, eb); ctx[5] = H(15, ch, ep, g);
      ctx[6] = H(16, ch, ep, ea);
    }
    const sym = decoding ? 0 : mode ? (data[i] - med) & 255 : data[i];
    let c0 = 1;
    for (let bp = 0; bp < 8; bp++) {
      const w = W[bp];
      const cmix = Math.imul(c0, 0x9e3779b1);
      let dot = 0;
      for (let k = 0; k < nin; k++) {
        const j = (ctx[k] + cmix) & TMASK;
        idx[k] = j;
        st[k] = STRETCH[P[k][j] >> 4];
        dot += w[k] * st[k]; // < 2^53, exact in doubles
      }
      let p12 = squash(Math.floor(dot / 65536));
      p12 = p12 < 1 ? 1 : p12 > 4095 ? 4095 : p12;
      const bit = coder.bit(p12, (sym >> (7 - bp)) & 1);
      const e = (bit << 12) - p12;
      for (let k = 0; k < nin; k++) {
        const nw = w[k] + ((st[k] * e * 20) >> 14);
        w[k] = nw > 4194304 ? 4194304 : nw < -4194304 ? -4194304 : nw;
        const j = idx[k], n = N[k][j], pk = P[k][j];
        const p = pk + ((((bit << 16) - pk) * RECIP[n]) >> 15);
        P[k][j] = p < 0 ? 0 : p > 65535 ? 65535 : p;
        if (n < 60) N[k][j] = n + 1;
      }
      c0 = c0 * 2 + bit;
    }
    const byte = c0 & 255;
    if (mode === 0) {
      if (decoding) data[i] = byte;
      c8 = ((c8 << 8) | (c4 >>> 24)) >>> 0;
      c4 = ((c4 << 8) | data[i]) >>> 0;
    } else {
      if (decoding) data[i] = (med + byte) & 255;
      err[i] = data[i] - med;
    }
  }
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "enc") {
  const mode = rest[0] === "image" ? 1 : 0;
  const width = mode ? parseInt(rest[1], 10) : 0;
  const [inp, out] = rest.slice(1 + mode);
  const data = new Uint8Array(readFileSync(inp));
  if (mode && (!width || data.length % (3 * width))) throw new Error("bad width");
  const c = makeCoder(null);
  run(c, mode, width, data, data.length, false);
  const bytes = new Uint8Array(c.len + 4);
  bytes.set(c.out.subarray(0, c.len));
  bytes.set([c.x1 >>> 24, (c.x1 >>> 16) & 255, (c.x1 >>> 8) & 255, c.x1 & 255], c.len);
  let n = bytes.length;
  while (n && bytes[n - 1] === 0) n--;
  const hdr = Buffer.alloc(13);
  hdr.write("FRC1", 0, "latin1"); hdr[4] = mode;
  hdr.writeUInt32LE(width, 5); hdr.writeUInt32LE(data.length, 9);
  writeFileSync(out, Buffer.concat([hdr, bytes.subarray(0, n)]));
} else if (cmd === "dec") {
  const f = readFileSync(rest[0]);
  if (f.length < 13 || f.toString("latin1", 0, 4) !== "FRC1") throw new Error("not an FRC1 file");
  const mode = f[4], width = f.readUInt32LE(5), L = f.readUInt32LE(9);
  const data = new Uint8Array(L);
  run(makeCoder(f.subarray(13)), mode, width, data, L, true);
  writeFileSync(rest[1], data);
} else {
  console.error("usage: fm.mjs enc bytes IN OUT | enc image WIDTH IN OUT | dec IN OUT");
  process.exit(2);
}
