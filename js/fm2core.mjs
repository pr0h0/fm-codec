// FM2 codec core, browser-compatible ES module (no node imports). Same spec as c/fm2.c
// (byte-identical output).
//   encode(data, { level = 3, mode = 'bytes' | 'image', width = 0 }) -> Uint8Array
//   decode(buf) -> Uint8Array

const TBITS = 22, TSIZE = 1 << TBITS, TMASK = TSIZE - 1, MAXIN = 12, HDR = 20;
const SQ_T = Int32Array.of(1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
  2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094);
function squash(d) {
  if (d > 2047) return 4095;
  if (d < -2047) return 1;
  const w = d & 127, i = (d >> 7) + 16;
  return (SQ_T[i] * (128 - w) + SQ_T[i + 1] * w + 64) >> 7;
}
const STRETCH = new Int32Array(4096), RECIP = new Int32Array(256);
{
  let pi = 0;
  for (let x = -2047; x <= 2047; x++) {
    const v = squash(x);
    for (let j = pi; j <= v; j++) STRETCH[j] = x;
    pi = v + 1;
  }
  for (let j = pi; j < 4096; j++) STRETCH[j] = 2047;
  for (let n = 0; n < 256; n++) RECIP[n] = Math.floor(65536 / (2 * n + 3));
}
// returns the uint32 hash as an int32 bit pattern
function H(k, a, b, c) {
  let h = Math.imul(k + 1, 0x9e3779b1);
  h = Math.imul(h ^ a, 0x85ebca6b); h ^= h >>> 13;
  h = Math.imul(h ^ b, 0xc2b2ae35); h ^= h >>> 16;
  h = Math.imul(h ^ c, 0x85ebca6b); h ^= h >>> 15;
  return h;
}
const clamp255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
const clampp = (p) => (p < 1 ? 1 : p > 4095 ? 4095 : p);
const qe = (e, lim) => (e < -lim ? -lim : e > lim ? lim : e) + 64;
function qg(d) {
  const a = d < 0 ? -d : d, q = a === 0 ? 0 : a < 3 ? 1 : a < 7 ? 2 : a < 21 ? 3 : 4;
  return (d < 0 ? -q : q) + 8;
}

const NIN_B = [0, 1, 3, 6, 6], NIN_I = [0, 3, 6, 9, 12];
const ORD2 = [1, 2, 3], ORD3 = [0, 1, 2, 3, 4, 6];

// Model + arithmetic coder in one hot function.
// Encoder (src == null): returns { out, len, x1 } with out[0..HDR) reserved for the header.
// Decoder: fills data[0..L) from src (payload bytes after the header).
function run(mode, prof, limit, width, data, L, src) {
  const dec = src !== null;
  const img = mode === 2;
  const nin = img ? NIN_I[prof] : NIN_B[prof];
  const direct = !img && prof === 1, mix2 = prof === 4, apm = prof === 4;
  const np = img ? (prof === 3 ? 5 : prof === 4 ? 9 : 0) : 0;
  const P = new Uint16Array(TSIZE * nin).fill(32768);
  const N = new Uint8Array(TSIZE * nin);
  const winit = Math.trunc((19661 * 6) / nin);
  const W1 = new Int32Array(128 * MAXIN).fill(winit), W2 = new Int32Array(768 * MAXIN).fill(winit);
  const napm = apm ? (img ? 256 * 16 * 3 : 65536) : 0;
  const A = new Uint16Array((napm || 1) * 33);
  if (napm) {
    for (let j = 0; j < 33; j++) A[j] = squash((j - 16) * 128) * 16;
    for (let k = 1; k < napm; k++) A.copyWithin(k * 33, 0, 33);
  }
  const err = new Int16Array(img ? L + 1 : 1);
  const perr = new Uint8Array(np ? (L + 1) * np : 1);
  const stride = 3 * width;
  const ctx = new Int32Array(MAXIN), idx = new Int32Array(MAXIN), st = new Int32Array(MAXIN), pr = new Int32Array(9);
  let c4 = 0, c8 = 0;
  let ch = 0, x = 0, y = 0; // image position of byte i

  // coder state (x1, x2, xc hold uint32 values as doubles)
  let x1 = 0, x2 = 0xffffffff, xc = 0, pos = 0, out = null, olen = 0;
  const slen = dec ? src.length : 0;
  if (dec) for (let i = 0; i < 4; i++) { xc = ((xc << 8) | (pos < slen ? src[pos] : 0)) >>> 0; pos++; }
  else { out = new Uint8Array(HDR + L + Math.floor(L / 8) + 1024); olen = HDR; }

  for (let i = 0; i < L; i++) {
    let act = 0, eP = 0, pred = 0, sym = 0;
    if (!img) {
      if (prof === 1) ctx[0] = H(2, c4 & 0xffff, 0, 0);
      else for (let k = 0; k < nin; k++) {
        const o = prof === 2 ? ORD2[k] : ORD3[k];
        const m = o >= 4 ? -1 : (1 << (8 * o)) - 1;
        ctx[k] = H(o, c4 & m, o === 6 ? c8 & 0xffff : 0, 0);
      }
      if (!dec) sym = data[i];
    } else {
      const hasW = x > 0, hasN = y > 0, hasNE = y > 0 && x < width - 1, hasWW = x > 1, hasNN = y > 1;
      const iW = i - 3, iN = i - stride, iNW = iN - 3, iNE = iN + 3;
      const Wv = hasW ? data[iW] : hasN ? data[iN] : 0;
      const Nv = hasN ? data[iN] : Wv;
      const NWv = hasN && hasW ? data[iNW] : Nv;
      const NEv = hasNE ? data[iNE] : Nv;
      const WWv = hasWW ? data[i - 6] : Wv;
      const NNv = hasNN ? data[iN - stride] : Nv;
      const mx = Wv > Nv ? Wv : Nv, mn = Wv < Nv ? Wv : Nv;
      pr[0] = NWv >= mx ? mn : NWv <= mn ? mx : Wv + Nv - NWv;
      pred = pr[0];
      if (np) {
        pr[1] = clamp255(Wv + Nv - NWv);
        pr[2] = (Wv + NEv + 1) >> 1;
        pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
        pr[4] = pr[0];
        if (ch > 0) {
          const pw = hasW ? data[iW - 1] : hasN ? data[iN - 1] : 0;
          const pn = hasN ? data[iN - 1] : pw;
          const pnw = hasN && hasW ? data[iNW - 1] : pn;
          const pmx = pw > pn ? pw : pn, pmn = pw < pn ? pw : pn;
          const pmed = pnw >= pmx ? pmn : pnw <= pmn ? pmx : pw + pn - pnw;
          pr[4] = clamp255(pr[0] + (data[i - 1] - pmed));
        }
        pr[5] = Wv; pr[6] = Nv; pr[7] = clamp255(2 * Wv - WWv); pr[8] = clamp255(2 * Nv - NNv);
        let num = 0, den = 0; // int64 in C; exact in doubles (< 2^40)
        for (let k = 0; k < np; k++) {
          let s = 1;
          if (hasW) s += perr[iW * np + k];
          if (hasN) s += perr[iN * np + k];
          if (hasN && hasW) s += perr[iNW * np + k];
          if (hasNE) s += perr[iNE * np + k];
          const w = Math.floor(16777216 / (s * s));
          num += w * pr[k]; den += w;
        }
        pred = Math.floor((num + Math.floor(den / 2)) / den);
      }
      const eW = hasW ? err[iW] : 0, eN = hasN ? err[iN] : 0, eNW = hasN && hasW ? err[iNW] : 0;
      const eNE = hasNE ? err[iNE] : 0, eP2 = ch === 2 ? err[i - 2] : 0;
      eP = ch ? err[i - 1] : 0;
      const av = (eW < 0 ? -eW : eW) + (eN < 0 ? -eN : eN) + (eNW < 0 ? -eNW : eNW) + (eNE < 0 ? -eNE : eNE);
      act = 32 - Math.clz32(av);
      if (act > 15) act = 15;
      const qp = ch ? qe(eP, 12) : 255;
      if (prof === 1) {
        ctx[0] = H(10, ch, 0, 0); ctx[1] = H(14, ch, qe(eW, 12), qe(eN, 12)); ctx[2] = H(15, ch, qp, act);
      } else {
        ctx[0] = H(10, ch, 0, 0);
        ctx[1] = H(11, ch, qe(eW, 12), 0);
        ctx[2] = H(12, ch, qe(eN, 12), 0);
        ctx[3] = H(13, ch, qp, ch ? 0 : 99);
        ctx[4] = H(14, ch, qe(eW, 12), qe(eN, 12));
        ctx[5] = H(15, ch, qp, act);
        if (prof >= 3) {
          ctx[6] = H(16, ch, qe(eNW, 8) * 256 + qe(eNE, 8), act);
          ctx[7] = H(17, ch, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
          ctx[8] = H(18, ch, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
        }
        if (prof === 4) {
          ctx[9] = H(19, ch, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
          ctx[10] = H(20, ch, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
          ctx[11] = H(21, ch, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
        }
      }
      if (!dec) { const s = ((data[i] - pred) << 24) >> 24; sym = s >= 0 ? 2 * s : -2 * s - 1; }
    }
    const sel1 = img && prof >= 3 ? act : 0;
    const w2row = img && ch ? qe(eP, 15) - 49 : 0;
    let c0 = 1;
    for (let bp = 0; bp < 8; bp++) {
      let p12, p1 = 0, p2 = 0, aidx = 0, awt = 0;
      const w1o = (bp * 16 + sel1) * MAXIN;
      const w2o = (img ? (bp * 3 + ch) * 32 + w2row : c0) * MAXIN;
      const cm = Math.imul(c0, 0x9e3779b1);
      let dot = 0, dot2 = 0; // int64 in C; exact in doubles (< 2^40)
      for (let k = 0; k < nin; k++) {
        const j = k * TSIZE + ((ctx[k] + cm) & TMASK);
        idx[k] = j;
        const s = STRETCH[P[j] >> 4];
        st[k] = s;
        dot += W1[w1o + k] * s;
        dot2 += W2[w2o + k] * s;
      }
      if (direct) p12 = clampp(P[idx[0]] >> 4);
      else {
        let d = Math.floor(dot / 65536);
        p1 = clampp(squash(d));
        if (mix2) {
          const d2 = Math.floor(dot2 / 65536);
          p2 = clampp(squash(d2));
          d = (d + d2) >> 1;
        }
        p12 = squash(d);
        if (apm) {
          const ds = d < -2047 ? -2047 : d > 2047 ? 2047 : d;
          const a = img ? (c0 * 16 + act) * 3 + ch : c0 | ((c4 & 255) << 8);
          const ps = (ds + 2048) * 32;
          awt = ps & 4095; aidx = a * 33 + (ps >> 12);
          const pa = (A[aidx] * (4096 - awt) + A[aidx + 1] * awt) >> 16;
          p12 = (p12 + 3 * pa) >> 2;
        }
        p12 = clampp(p12);
      }
      // binary arithmetic coder
      let bit;
      const xmid = x1 + ((x2 - x1) >>> 12) * p12;
      if (dec) bit = xc <= xmid ? 1 : 0;
      else bit = (sym >> (7 - bp)) & 1;
      if (bit) x2 = xmid; else x1 = xmid + 1;
      while (((x1 ^ x2) & 0xff000000) === 0) {
        if (dec) { xc = ((xc << 8) | (pos < slen ? src[pos] : 0)) >>> 0; pos++; }
        else {
          if (olen === out.length) { const nb = new Uint8Array(olen * 2); nb.set(out); out = nb; }
          out[olen++] = x2 >>> 24;
        }
        x1 = (x1 << 8) >>> 0;
        x2 = ((x2 << 8) | 255) >>> 0;
      }
      if (!direct) {
        const e1 = (bit << 12) - p1;
        for (let k = 0; k < nin; k++) {
          const nw = W1[w1o + k] + ((st[k] * e1 * 20) >> 14);
          W1[w1o + k] = nw > 4194304 ? 4194304 : nw < -4194304 ? -4194304 : nw;
        }
        if (mix2) {
          const e2 = (bit << 12) - p2;
          for (let k = 0; k < nin; k++) {
            const nw = W2[w2o + k] + ((st[k] * e2 * 20) >> 14);
            W2[w2o + k] = nw > 4194304 ? 4194304 : nw < -4194304 ? -4194304 : nw;
          }
        }
        if (apm) {
          const g = bit ? 65566 : 0; // (bit<<16) + (bit<<5) - 2*bit
          const j = awt >> 11 ? aidx + 1 : aidx;
          A[j] += (g - A[j]) >> 6;
        }
      }
      for (let k = 0; k < nin; k++) {
        const j = idx[k], n = N[j], pj = P[j];
        const p = pj + ((((bit << 16) - pj) * RECIP[n]) >> 15);
        P[j] = p < 0 ? 0 : p > 65535 ? 65535 : p;
        if (n < limit) N[j] = n + 1;
      }
      c0 = c0 * 2 + bit;
    }
    const v = c0 & 255;
    if (!img) {
      if (dec) data[i] = v;
      c8 = (c8 << 8) | (c4 >>> 24);
      c4 = (c4 << 8) | data[i];
    } else {
      if (dec) data[i] = pred + (v & 1 ? -((v + 1) >> 1) : v >> 1); // Uint8Array store wraps like (uint8_t)
      err[i] = ((data[i] - pred) << 24) >> 24;
      for (let k = 0; k < np; k++) {
        const ek = data[i] - pr[k];
        perr[i * np + k] = ek < 0 ? (ek < -255 ? 255 : -ek) : ek > 255 ? 255 : ek;
      }
      if (++ch === 3) { ch = 0; if (++x === width) { x = 0; y++; } }
    }
  }
  return { out, len: olen, x1 };
}

function writeHeader(h, mode, prof, limit, width, L) {
  h[0] = 0x46; h[1] = 0x4d; h[2] = 0x32; h[3] = 1;
  h[4] = mode; h[5] = prof; h[6] = limit; h[7] = 0;
  const dv = new DataView(h.buffer, h.byteOffset, HDR);
  dv.setUint32(8, width >>> 0, true);
  dv.setUint32(12, L >>> 0, true);
  dv.setUint32(16, Math.floor(L / 4294967296) >>> 0, true);
}

function encodeOne(mode, prof, limit, width, data, L) {
  let { out, len, x1 } = run(mode, prof, limit, width, data, L, null);
  if (len + 4 > out.length) { const nb = new Uint8Array(len + 4); nb.set(out); out = nb; }
  for (let i = 3; i >= 0; i--) out[len++] = (x1 >>> (8 * i)) & 255;
  while (len > HDR && out[len - 1] === 0) len--;
  writeHeader(out, mode, prof, limit, width, L);
  return out.slice(0, len);
}

// [profile, counter limit] candidates per level
const CB = [[], [[1, 60]], [[2, 60]], [[3, 60]], [[4, 255]], [[4, 255], [4, 60], [3, 255]]];
const CI = [[], [[1, 60]], [[2, 60]], [[3, 255]], [[4, 255]], [[4, 255]]];

export function encode(data, { level = 3, mode = "bytes", width = 0 } = {}) {
  const m = mode === "image" ? 2 : 1, L = data.length;
  if (!(level >= 0 && level <= 5) || level !== Math.floor(level)) throw new RangeError("level must be 0..5");
  if (m === 2 && (!(width > 0) || L % (3 * width))) throw new RangeError("bad width");
  let best = null;
  for (const [prof, limit] of (m === 2 ? CI : CB)[level]) {
    const o = encodeOne(m, prof, limit, width, data, L);
    if (!best || o.length < best.length) best = o;
  }
  if (!best || best.length >= L + HDR) { // store
    best = new Uint8Array(L + HDR);
    writeHeader(best, 0, 0, 0, width, L);
    best.set(data, HDR);
  }
  return best;
}

export function decode(f) {
  if (f.length < HDR || f[0] !== 0x46 || f[1] !== 0x4d || f[2] !== 0x32 || f[3] !== 1) throw new Error("not an FM2 file");
  const dv = new DataView(f.buffer, f.byteOffset, HDR);
  const mode = f[4], prof = f[5], limit = f[6];
  const width = dv.getUint32(8, true), L = dv.getUint32(12, true) + dv.getUint32(16, true) * 4294967296;
  if (mode === 0) {
    if (f.length - HDR < L) throw new Error("truncated FM2 file");
    return f.slice(HDR, HDR + L);
  }
  if (mode > 2 || prof < 1 || prof > 4 || (mode === 2 && !width)) throw new Error("bad FM2 header");
  const data = new Uint8Array(L);
  run(mode, prof, limit, width, data, L, f.subarray(HDR));
  return data;
}
