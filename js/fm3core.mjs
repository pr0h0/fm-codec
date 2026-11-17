// FM3 codec core, browser-compatible ES module (no node imports). Port of c/fm3.c, which is the
// spec (see its header comment); output is byte-identical to the C binary.
//   encode(data, { level = 3, mode = 'bytes' | 'image', width = 0 }) -> Uint8Array
//   decode(buf) -> Uint8Array
// The C experiment env overrides (FEAT/BB/LIMIT/LR) are not ported.

const MAXIN = 48, HDR = 28;
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
// returns the uint32 hash as an int32 bit pattern (use >>> for unsigned shifts)
function H(k, a, b, c) {
  let h = Math.imul(k + 1, 0x9e3779b1);
  h = Math.imul(h ^ a, 0x85ebca6b); h ^= h >>> 13;
  h = Math.imul(h ^ b, 0xc2b2ae35); h ^= h >>> 16;
  h = Math.imul(h ^ c, 0x85ebca6b); h ^= h >>> 15;
  return h;
}
const clamp255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
const clampp = (p) => (p < 1 ? 1 : p > 4095 ? 4095 : p);
const clampd = (d) => (d < -2047 ? -2047 : d > 2047 ? 2047 : d);
const qe = (e, lim) => (e < -lim ? -lim : e > lim ? lim : e) + 64;
function qg(d) {
  const a = d < 0 ? -d : d, q = a === 0 ? 0 : a < 3 ? 1 : a < 7 ? 2 : a < 21 ? 3 : 4;
  return (d < 0 ? -q : q) + 8;
}
function apmInit(n) {
  const A = new Uint16Array(n * 33);
  for (let j = 0; j < 33; j++) A[j] = squash((j - 16) * 128) * 16;
  for (let k = 33; k < A.length; k *= 2) A.copyWithin(k, 0, Math.min(k, A.length - k));
  return A;
}

const ORD = [0, 1, 2, 3, 4, 6, 5, 7];
const TB_IMG = [8, 12, 12, 12, 16, 16, 0, 17, 0, 0, 0, 0, 17, 16, 16, 0];
const ENTRY0 = 32768 | (1 << 24);

// Model + arithmetic coder in one hot function.
// Encoder (src === null): returns { out, len, x1 } with out[0..HDR) reserved for the header.
// Decoder: fills data[0..L) from src (payload bytes after the header).
function run(mode, bb, limit, lr, feat, width, data, L, src) {
  const dec = src !== null, img = mode === 2;
  const flite = (feat & (1 << 21)) !== 0;
  const fmatch = !img && (feat & 1) !== 0, fword = !img && (feat & 2) !== 0, fmsel = !img && (feat & 4) !== 0;
  const fapm2 = !img && (feat & 8) !== 0, fhi = !img && !flite && (feat & 16) !== 0, fmix2 = (feat & 32) !== 0;
  const fsparse = !img && (feat & 128) !== 0, fmix3 = fmix2 && (feat & 256) !== 0;
  const fimgx = img && !flite && (feat & 512) !== 0, fhist = !img && (feat & 2048) !== 0;
  const find = !img && (feat & 32768) !== 0, fmapm = fmatch && fmix2 && (feat & 65536) !== 0;
  const fm2nd = fmatch && (feat & 131072) !== 0, fcol = !img && (feat & 262144) !== 0;
  const fblend1 = img && (feat & (1 << 20)) !== 0;

  const nord = flite ? 3 : 6 + (fhi ? 2 : 0);
  const bword = nord, bsparse = bword + (fword ? 2 : 0), bind = bsparse + (fsparse ? 3 : 0), bcol = bind + (find ? 2 : 0);
  const nctx = img ? (flite ? 6 : 12 + (fimgx ? 4 : 0)) : bcol + (fcol ? 2 : 0);
  const nin = nctx * (fhist ? 2 : 1) + (fmatch ? 1 : 0) + (fm2nd ? 1 : 0) + 1;
  const np = img && !flite ? 9 : 0;

  // context tables: one array, per-context offsets; low-cardinality contexts get small tables
  const tb = new Int32Array(MAXIN), tbase = new Int32Array(MAXIN);
  for (let k = 0; k < nctx; k++) tb[k] = bb;
  if (img) { for (let k = 0; k < nctx; k++) if (TB_IMG[k] && TB_IMG[k] < bb) tb[k] = TB_IMG[k]; }
  else {
    if (flite) tb[0] = 13 < bb ? 13 : bb;
    else { tb[0] = 6; tb[1] = 13 < bb ? 13 : bb; }
    if (fsparse) { tb[bsparse] = 13 < bb ? 13 : bb; tb[bsparse + 2] = 15 < bb ? 15 : bb; }
  }
  let total = 0;
  for (let k = 0; k < nctx; k++) { tbase[k] = total; total += 16 << tb[k]; }
  const T = new Int32Array(total).fill(ENTRY0); // entries: p16 | n8 << 16 | hist8 << 24 (int32 bit pattern)
  for (let j = 0; j < total; j += 16) T[j] = 0;

  const SM = new Int32Array(MAXIN * 256).fill(32768);
  const winit = Math.trunc((19661 * 6) / nin);
  const W1 = new Int32Array(128 * MAXIN).fill(winit), W2 = new Int32Array(768 * MAXIN).fill(winit);
  const W3 = new Int32Array(fmix3 ? 2048 * MAXIN : 1).fill(winit), WF = new Int32Array(256 * 3).fill(21845);
  const A1 = apmInit(fmix2 ? (img ? 256 * 16 * 3 : 65536) : 1);
  const A2 = apmInit(fapm2 ? 1 << 18 : 1), A3 = apmInit(fmapm ? 65536 : 1);
  const MT = new Int32Array(fmatch ? 1 << 22 : 1), MT2 = new Int32Array(fm2nd ? 1 << 22 : 1);
  const MP = new Uint16Array(64).fill(49152), MP2 = new Uint16Array(64).fill(49152);
  const MN = new Uint8Array(64), MN2 = new Uint8Array(64);
  const IND1 = new Uint16Array(256), IND2 = new Uint16Array(find ? 1 << 22 : 1);
  const err = new Int16Array(img ? L + 1 : 1);
  const perr = new Uint8Array(np ? (L + 1) * np : 1);
  const stride = 3 * width;
  let mptr = 0, mlen = 0, mptr2 = 0, mlen2 = 0, linestart = 0, prevline = 0;
  const ctx = new Int32Array(MAXIN), bk = new Int32Array(MAXIN), st = new Int32Array(MAXIN + 2);
  const smi = new Int32Array(MAXIN), pr = new Int32Array(9);
  let c4 = 0, c8 = 0, wh0 = 0, wh1 = 0, wh2 = 0;
  let ch = 0, x = 0, y = 0; // image position of byte i

  // coder state (x1, x2, xc hold uint32 values as doubles)
  let x1 = 0, x2 = 0xffffffff, xc = 0, pos = 0, out = null, olen = 0;
  const slen = dec ? src.length : 0;
  if (dec) for (let i = 0; i < 4; i++) { xc = ((xc << 8) | (pos < slen ? src[pos] : 0)) >>> 0; pos++; }
  else { out = new Uint8Array(HDR + (L >> 1) + 1024); olen = HDR; }

  for (let i = 0; i < L; i++) {
    let act = 0, eP = 0, pred = 0, sym = 0, mb = -1, lenq = 0, msel = 0, mb2 = -1, lenq2 = 0, h52 = 0, h77 = 0;
    if (!img) {
      for (let k = 0; k < nord; k++) {
        const o = flite ? k + 1 : ORD[k];
        const m = o >= 4 ? -1 : (1 << (8 * o)) - 1;
        const hi = o === 6 ? c8 & 0xffff : o === 5 ? c8 & 0xff : o === 7 ? c8 & 0xffffff : 0;
        ctx[k] = H(o, c4 & m, hi, 0);
      }
      if (fword) { ctx[bword] = H(30, wh0, 0, 0); ctx[bword + 1] = H(31, wh0, wh1, 0); }
      if (fsparse) {
        ctx[bsparse] = H(40, (c4 >>> 8) & 0xff, 0, 0);
        ctx[bsparse + 1] = H(41, (c4 >>> 16) & 0xffff, 0, 0);
        ctx[bsparse + 2] = H(42, i & 3, c4 & 0xff, 0);
      }
      if (find) {
        h52 = H(52, c4 & 0xffff, 0, 0) >>> 10;
        ctx[bind] = H(50, c4 & 0xff, IND1[c4 & 0xff], 0);
        ctx[bind + 1] = H(51, c4 & 0xffff, IND2[h52], 0);
      }
      if (fcol) {
        const col = i - linestart, ab = prevline + col;
        const above = ab < linestart ? data[ab] : 0;
        ctx[bcol] = H(60, above, col > 255 ? 255 : col, c4 & 0xff);
        ctx[bcol + 1] = H(61, wh0, wh1, wh2);
      }
      if (fmatch) {
        if (mlen > 0) { if (data[mptr] === data[i - 1]) { mlen++; mptr++; } else mlen = 0; }
        if (i >= 6) {
          const h = H(99, c4, c8 & 0xffff, 0) >>> 10;
          if (mlen === 0 && MT[h] > 0) {
            const cand = MT[h];
            let len = 0;
            while (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] === data[i - 1 - len]) len++;
            if (len >= 6) { mlen = len; mptr = cand; }
          }
          MT[h] = i;
        }
        if (fm2nd) {
          if (mlen2 > 0) { if (data[mptr2] === data[i - 1]) { mlen2++; mptr2++; } else mlen2 = 0; }
          if (i >= 12) {
            const far = data[i - 9] | (data[i - 10] << 8) | (data[i - 11] << 16) | (data[i - 12] << 24);
            const hh = H(98, c4, c8, far) >>> 10;
            if (mlen2 === 0 && MT2[hh] > 0 && MT2[hh] !== mptr) {
              const cand = MT2[hh];
              let len = 0;
              while (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] === data[i - 1 - len]) len++;
              if (len >= 12) { mlen2 = len; mptr2 = cand; }
            }
            MT2[hh] = i;
          }
          if (mlen2 > 65535) mlen2 = 65535;
          if (mlen2 > 0) {
            mb2 = data[mptr2];
            lenq2 = mlen2 < 16 ? mlen2 : 16 + ((mlen2 - 16) >> 4 > 15 ? 15 : (mlen2 - 16) >> 4);
          }
        }
        if (mlen > 65535) mlen = 65535;
        if (mlen > 0) {
          mb = data[mptr];
          lenq = mlen < 16 ? mlen : 16 + ((mlen - 16) >> 4 > 15 ? 15 : (mlen - 16) >> 4);
          msel = mlen < 16 ? 1 : mlen < 32 ? 2 : 3;
        }
      }
      if (fapm2) h77 = (H(77, c4 & 0xffff, 0, 0) >>> 22) << 8;
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
      pr[0] = NWv >= mx ? mn : NWv <= mn ? mx : Wv + Nv - NWv; // MED
      pred = pr[0];
      if (np) {
        pr[1] = clamp255(Wv + Nv - NWv);
        pr[2] = (Wv + NEv + 1) >> 1;
        pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
        pr[4] = pr[0];
        if (ch > 0) { // cross-channel: MED + previous channel's MED error
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
          const w = fblend1 ? Math.floor(16777216 / s) : Math.floor(16777216 / (s * s));
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
      ctx[0] = H(10, ch, 0, 0);
      ctx[1] = H(11, ch, qe(eW, 12), 0);
      ctx[2] = H(12, ch, qe(eN, 12), 0);
      ctx[3] = H(13, ch, qp, ch ? 0 : 99);
      ctx[4] = H(14, ch, qe(eW, 12), qe(eN, 12));
      ctx[5] = H(15, ch, qp, act);
      if (!flite) {
        ctx[6] = H(16, ch, qe(eNW, 8) * 256 + qe(eNE, 8), act);
        ctx[7] = H(17, ch, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
        ctx[8] = H(18, ch, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
        ctx[9] = H(19, ch, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
        ctx[10] = H(20, ch, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
        ctx[11] = H(21, ch, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
      }
      if (fimgx) {
        const eWW = hasWW ? err[i - 6] : 0, eNN = hasNN ? err[iN - stride] : 0;
        ctx[12] = H(22, ch, Wv >> 3, Nv >> 3);
        ctx[13] = H(23, ch, qe(eWW, 12) * 256 + qe(eNN, 12), 0);
        ctx[14] = H(24, ch, pred >> 3, act);
        ctx[15] = H(25, ch, ch ? qe(eP, 8) : 255, qe(eW, 6) * 256 + qe(eN, 6));
      }
      if (!dec) { const s = ((data[i] - pred) << 24) >> 24; sym = s >= 0 ? 2 * s : -2 * s - 1; }
    }
    const sel1 = img ? act : fmsel ? msel : 0;
    const w2row = img && ch ? qe(eP, 15) - 49 : 0;
    let c0 = 1, node = 1, mmiss = 0, mmiss2 = 0;
    for (let bp = 0; bp < 8; bp++) {
      if (bp === 0 || bp === 4) { // find the bucket of every context for this nibble
        const cm = Math.imul(c0, 0x9e3779b1);
        for (let k = 0; k < nctx; k++) {
          let h = (ctx[k] + cm) | 0; // nib_hash
          h ^= h >>> 15; h = Math.imul(h, 0x2c1b3c6d); h ^= h >>> 12; h = Math.imul(h, 0x297a2d39); h ^= h >>> 15;
          let chk = Math.imul(h, 0x2545f491) >>> 16;
          if (chk === 0) chk = 1;
          const i0 = h >>> (32 - tb[k]);
          const b0 = tbase[k] + (i0 << 4), b1 = tbase[k] + ((i0 ^ 1) << 4);
          let b;
          if ((T[b0] & 0xffff) === chk) b = b0;
          else if ((T[b1] & 0xffff) === chk) b = b1;
          else {
            b = ((T[b0 + 1] >>> 16) & 255) <= ((T[b1 + 1] >>> 16) & 255) ? b0 : b1;
            T[b] = chk;
            for (let j = 1; j < 16; j++) T[b + j] = ENTRY0;
          }
          bk[k] = b;
        }
        node = 1;
      }
      let n = 0;
      for (let k = 0; k < nctx; k++) st[n++] = STRETCH[(T[bk[k] + node] & 0xffff) >> 4];
      if (fhist) for (let k = 0; k < nctx; k++) {
        const si = k * 256 + (T[bk[k] + node] >>> 24);
        smi[k] = si;
        st[n++] = STRETCH[(SM[si] & 0xffff) >> 4];
      }
      let eb = -1, mq = 0, eb2 = -1, mq2 = 0;
      if (fmatch) {
        if (mb >= 0 && !mmiss) {
          eb = (mb >> (7 - bp)) & 1; mq = lenq * 2 + (bp === 0 ? 1 : 0);
          const sp = STRETCH[MP[mq] >> 4];
          st[n++] = eb ? sp : 0 - sp; // 0 - sp: avoids -0 deopts
        } else st[n++] = 0;
      }
      if (fm2nd) {
        if (mb2 >= 0 && !mmiss2) {
          eb2 = (mb2 >> (7 - bp)) & 1; mq2 = lenq2 * 2 + (bp === 0 ? 1 : 0);
          const sp = STRETCH[MP2[mq2] >> 4];
          st[n++] = eb2 ? sp : 0 - sp;
        } else st[n++] = 0;
      }
      st[n++] = 256; // bias
      const o1 = (bp * 16 + sel1) * MAXIN;
      const o2 = (img ? (bp * 3 + ch) * 32 + w2row : c0) * MAXIN;
      const o3 = ((img ? ch * 256 + c0 : ((c4 & 0xff) << 3) | bp) & 2047) * MAXIN;
      const of = c0 * 3;
      // dot32: s += (w*st) >> 8 (products < 2^31), then s >> 8
      let s1 = 0, s2 = 0, s3 = 0;
      if (fmix3) for (let k = 0; k < nin; k++) {
        const s = st[k];
        s1 = (s1 + ((W1[o1 + k] * s) >> 8)) | 0;
        s2 = (s2 + ((W2[o2 + k] * s) >> 8)) | 0;
        s3 = (s3 + ((W3[o3 + k] * s) >> 8)) | 0;
      } else if (fmix2) for (let k = 0; k < nin; k++) {
        const s = st[k];
        s1 = (s1 + ((W1[o1 + k] * s) >> 8)) | 0;
        s2 = (s2 + ((W2[o2 + k] * s) >> 8)) | 0;
      } else for (let k = 0; k < nin; k++) s1 = (s1 + ((W1[o1 + k] * st[k]) >> 8)) | 0;
      const d1 = s1 >> 8, p1 = clampp(squash(d1));
      let d = d1, p2 = 0, p3 = 0, pf = 0, dd0 = 0, dd1 = 0, dd2 = 0;
      if (fmix2) {
        const d2 = s2 >> 8;
        p2 = clampp(squash(d2));
        d = (d1 + d2) >> 1;
        if (fmix3) { // learned final mixer over the three mixer outputs (int64 in C; exact in doubles)
          dd0 = clampd(d1); dd1 = clampd(d2); dd2 = clampd(s3 >> 8);
          p3 = clampp(squash(dd2));
          d = Math.floor((WF[of] * dd0 + WF[of + 1] * dd1 + WF[of + 2] * dd2) / 65536);
          pf = clampp(squash(d));
        }
      }
      let p12 = squash(d), ai1 = 0, ai2 = 0, ai3 = 0, aw = 0, a3used = false;
      if (fmix2) { // APMs, all interpolated on the same d
        const ps = (clampd(d) + 2048) * 32, ab = ps >> 12;
        aw = ps & 4095;
        ai1 = (img ? (c0 * 16 + act) * 3 + ch : c0 | ((c4 & 255) << 8)) * 33 + ab;
        const pa = (A1[ai1] * (4096 - aw) + A1[ai1 + 1] * aw) >> 16;
        if (fapm2) {
          ai2 = (h77 | c0) * 33 + ab;
          const pb = (A2[ai2] * (4096 - aw) + A2[ai2 + 1] * aw) >> 16;
          p12 = (2 * p12 + 3 * pa + 3 * pb) >> 3;
        } else p12 = (p12 + 3 * pa) >> 2;
        if (fmapm && mb >= 0 && !mmiss) {
          ai3 = ((((mb + 256) >> (7 - bp)) & 255) | ((lenq > 15 ? 15 : lenq) << 8) | 4096) * 33 + ab;
          p12 = (p12 + ((A3[ai3] * (4096 - aw) + A3[ai3 + 1] * aw) >> 16)) >> 1;
          a3used = true;
        }
      }
      p12 = clampp(p12);
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
      // upd32: w += (st * (err*LR)) >> 14, clamp [-2^19, 2^19-1]
      const e1 = ((bit << 12) - p1) * lr, e2 = ((bit << 12) - p2) * lr, e3 = ((bit << 12) - p3) * lr;
      if (fmix3) for (let k = 0; k < nin; k++) {
        const s = st[k];
        let nw = W1[o1 + k] + ((s * e1) >> 14);
        W1[o1 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
        nw = W2[o2 + k] + ((s * e2) >> 14);
        W2[o2 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
        nw = W3[o3 + k] + ((s * e3) >> 14);
        W3[o3 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
      } else if (fmix2) for (let k = 0; k < nin; k++) {
        const s = st[k];
        let nw = W1[o1 + k] + ((s * e1) >> 14);
        W1[o1 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
        nw = W2[o2 + k] + ((s * e2) >> 14);
        W2[o2 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
      } else for (let k = 0; k < nin; k++) {
        const nw = W1[o1 + k] + ((st[k] * e1) >> 14);
        W1[o1 + k] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
      }
      if (fmix2) {
        if (fmix3) {
          const ef = ((bit << 12) - pf) * lr;
          let nw = WF[of] + ((dd0 * ef) >> 14);
          WF[of] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
          nw = WF[of + 1] + ((dd1 * ef) >> 14);
          WF[of + 1] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
          nw = WF[of + 2] + ((dd2 * ef) >> 14);
          WF[of + 2] = nw > 524287 ? 524287 : nw < -524288 ? -524288 : nw;
        }
        const g = bit ? 65566 : 0, up = aw >> 11; // (bit<<16) + (bit<<5) - 2*bit
        A1[ai1 + up] += (g - A1[ai1 + up]) >> 6;
        if (fapm2) A2[ai2 + up] += (g - A2[ai2 + up]) >> 6;
        if (a3used) A3[ai3 + up] += (g - A3[ai3 + up]) >> 6;
      }
      for (let k = 0; k < nctx; k++) {
        const j = bk[k] + node, e = T[j], p = e & 0xffff;
        let cnt = (e >>> 16) & 255, hb = e >>> 24;
        const np2 = p + ((((bit << 16) - p) * RECIP[cnt]) >> 15);
        if (cnt < limit) cnt++;
        if (fhist) {
          const si = smi[k], sv = SM[si], sn = sv >>> 16;
          const sp = (sv & 0xffff) + ((((bit << 16) - (sv & 0xffff)) * RECIP[sn]) >> 15);
          SM[si] = sp | ((sn < 255 ? sn + 1 : 255) << 16);
        }
        hb = (hb << 1) | bit;
        if (hb >= 256) hb = (hb & 0x7f) | 0x80;
        T[j] = np2 | (cnt << 16) | (hb << 24);
      }
      if (eb >= 0) {
        const ok = bit === eb ? 1 : 0, cnt = MN[mq];
        MP[mq] += (((ok << 16) - MP[mq]) * RECIP[cnt]) >> 15;
        if (cnt < 255) MN[mq] = cnt + 1;
        if (!ok) mmiss = 1;
      }
      if (eb2 >= 0) {
        const ok = bit === eb2 ? 1 : 0, cnt = MN2[mq2];
        MP2[mq2] += (((ok << 16) - MP2[mq2]) * RECIP[cnt]) >> 15;
        if (cnt < 255) MN2[mq2] = cnt + 1;
        if (!ok) mmiss2 = 1;
      }
      c0 = c0 * 2 + bit;
      node = node * 2 + bit;
    }
    const v = c0 & 255;
    if (!img) {
      if (dec) data[i] = v;
      const b = data[i];
      if (find) {
        IND1[c4 & 0xff] = (IND1[c4 & 0xff] << 8) | b; // Uint16Array store truncates like (uint16_t)
        IND2[h52] = (IND2[h52] << 8) | b;
      }
      if (b === 10) { prevline = linestart; linestart = i + 1; }
      c8 = (c8 << 8) | (c4 >>> 24);
      c4 = (c4 << 8) | b;
      if (fword) {
        if ((b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b === 95 || b >= 128)
          wh0 = Math.imul((wh0 + (b | 32) + 1) | 0, 0x01000193);
        else if (wh0) { wh2 = wh1; wh1 = wh0; wh0 = 0; }
      }
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

function e8e9Detect(d, n) {
  let cnt = 0, good = 0;
  for (let i = 0; i + 4 < n; i++) if (d[i] === 0xe8 || d[i] === 0xe9) { cnt++; if (d[i + 4] === 0 || d[i + 4] === 0xff) good++; }
  return cnt > Math.floor(n / 256) && good * 2 > cnt;
}
// x86 CALL/JMP rel32 <-> absolute; positions are decided by the opcode byte, which never changes
function e8e9(d, n, fwd) {
  for (let i = 0; i + 4 < n;) {
    if (d[i] === 0xe8 || d[i] === 0xe9) {
      let v = d[i + 1] | (d[i + 2] << 8) | (d[i + 3] << 16) | (d[i + 4] << 24);
      v = fwd ? (v + i + 5) | 0 : (v - (i + 5)) | 0;
      d[i + 1] = v; d[i + 2] = v >> 8; d[i + 3] = v >> 16; d[i + 4] = v >> 24;
      i += 5;
    } else i++;
  }
}

function writeHeader(h, mode, bb, limit, lr, feat, width, L) {
  h[0] = 0x46; h[1] = 0x4d; h[2] = 0x33; h[3] = 1;
  h[4] = mode; h[5] = bb; h[6] = limit; h[7] = lr;
  const dv = new DataView(h.buffer, h.byteOffset, HDR);
  dv.setUint32(8, feat >>> 0, true);
  dv.setUint32(12, width >>> 0, true);
  dv.setUint32(16, L >>> 0, true);
  dv.setUint32(20, Math.floor(L / 4294967296) >>> 0, true);
}

const LR = 4, LIMIT = 255;
function encodeOne(mode, bb, feat, width, data, L) {
  let { out, len, x1 } = run(mode, bb, LIMIT, LR, feat, width, data, L, null);
  if (len + 4 > out.length) { const nb = new Uint8Array(len + 4); nb.set(out); out = nb; }
  for (let i = 3; i >= 0; i--) out[len++] = (x1 >>> (8 * i)) & 255;
  while (len > HDR && out[len - 1] === 0) len--;
  writeHeader(out, mode, bb, LIMIT, LR, feat, width, L);
  return out.slice(0, len);
}

// level feature sets (see c/fm3.c)
const B_L1 = (1 << 21) | 1 | 4, B_L2 = 1 | 2 | 4 | 32;
const B_L3 = B_L2 | 8 | 128 | 32768 | 65536 | 131072 | 262144, B_L4 = B_L3 | 16 | 256 | 2048;
const I_L1 = 1 << 21, I_L2 = 1 << 20, I_L3 = I_L2 | 32, I_L4 = I_L3 | 256 | 512;
const BL = [0, B_L1, B_L2, B_L3, B_L4, B_L4], IL = [0, I_L1, I_L2, I_L3, I_L4, I_L4];

export function encode(data, { level = 3, mode = "bytes", width = 0 } = {}) {
  const m = mode === "image" ? 2 : 1, L = data.length;
  if (!(level >= 0 && level <= 5) || level !== Math.floor(level)) throw new RangeError("level must be 0..5");
  if (m === 2 && (!(width > 0) || L % (3 * width))) throw new RangeError("bad width");
  if (m === 1) width = 0;
  const cands = []; // [feat, bb]; >1 candidate = one pass each, smallest wins
  if (level >= 1) {
    cands.push([m === 2 ? IL[level] : BL[level], level === 5 && m === 1 ? 19 : 18]);
    if (level === 5 && m === 2) cands.push([I_L4 & ~(1 << 20), 18]);
  }
  let xf = 8192, src = data;
  if (cands.length && m === 1 && e8e9Detect(data, L)) { src = data.slice(); e8e9(src, L, true); xf |= 64; }
  let best = null;
  for (const [f, bb] of cands) {
    const o = encodeOne(m, bb, (f & ~(64 | 8192)) | xf, width, src, L);
    if (!best || o.length < best.length) best = o;
  }
  if (!best || best.length >= L + HDR) { // store
    best = new Uint8Array(L + HDR);
    writeHeader(best, 0, 0, 0, 0, 0, width, L);
    best.set(data, HDR);
  }
  return best;
}

export function decode(f) {
  if (f.length < HDR || f[0] !== 0x46 || f[1] !== 0x4d || f[2] !== 0x33 || f[3] !== 1) throw new Error("not an FM3 file");
  const dv = new DataView(f.buffer, f.byteOffset, HDR);
  const mode = f[4], bb = f[5], limit = f[6], lr = f[7], feat = dv.getUint32(8, true);
  const width = dv.getUint32(12, true), L = dv.getUint32(16, true) + dv.getUint32(20, true) * 4294967296;
  if (mode === 0) {
    if (f.length - HDR < L) throw new Error("truncated FM3 file");
    return f.slice(HDR, HDR + L);
  }
  if (mode > 2 || bb < 1 || bb > 24 || (mode === 2 && (!width || L % (3 * width)))) throw new Error("bad FM3 header");
  const data = new Uint8Array(L);
  run(mode, bb, limit, lr, feat, width, data, L, f.subarray(HDR));
  if (feat & 64) e8e9(data, L, false);
  return data;
}
