"""Model-guided fraction encoding: data -> one number N, read as the fraction N / 256^k.

fracenc.py picks N/D inside the interval [T/256^L, (T+1)/256^L). Its width is always 256^-L,
so the number needs L bytes no matter how the search is done.

Here the interval is chosen by a probability model instead: every bit narrows the current interval
in proportion to how likely the model thought that bit was. Final width = P(data), so the number
needs only -log2 P(data) bits. A model that predicts well => wide interval => short number.
(This is arithmetic coding; the "fraction" is the whole file.)

Modes:
  bytes : context-mixing model over orders 0-6 of previous bytes (text, code, any file)
  image : raw RGB pixels; codes MED-predictor residuals with neighbour-aware contexts
"""
import math
from array import array

TBITS = 22
MASK = (1 << TBITS) - 1
ST = [math.log(max(p, 0.5) / max(4096 - p, 0.5)) for p in range(4097)]  # stretch(p12)
RECIP = [int(65536 / (n + 1.5)) for n in range(256)]
LIMIT = 60      # counter adaptation limit (higher = more stationary)
LR = 0.02       # mixer learning rate
# ponytail: math.exp in the mixer -> encoder/decoder must share a libm; use integer squash for portability.


def _run(L, ctx_of, sym_of, put, coder, ninputs):
    P = [array("H", [32768]) * (MASK + 1) for _ in range(ninputs)]
    C = [array("B", bytes(MASK + 1)) for _ in range(ninputs)]
    W = [[0.3] * ninputs for _ in range(8)]
    rng = range(ninputs)
    exp = math.exp
    for i in range(L):
        hs = ctx_of(i)
        sym = sym_of(i)
        c0 = 1
        for bp in range(8):
            w = W[bp]
            mix = c0 * 0x9E3779B1
            idx = [(hs[k] + mix) & MASK for k in rng]
            st = [ST[P[k][idx[k]] >> 4] for k in rng]
            dot = sum(w[k] * st[k] for k in rng)
            p = 1.0 / (1.0 + exp(-dot)) if dot > -30 else 1e-13
            p12 = min(4095, max(1, int(p * 4096)))
            bit = coder(p12, (sym >> (7 - bp)) & 1)
            err = (bit - p) * LR
            for k in rng:
                w[k] += err * st[k]
                j = idx[k]; n = C[k][j]; pk = P[k][j]
                pk += (((bit << 16) - pk) * RECIP[n]) >> 16
                P[k][j] = min(65535, max(0, pk))
                if n < LIMIT:
                    C[k][j] = n + 1
            c0 = c0 * 2 + bit
        put(i, c0 & 255)


def _encoder():
    st = {"x1": 0, "x2": 0xFFFFFFFF}; out = bytearray()

    def enc(p12, bit):
        x1, x2 = st["x1"], st["x2"]
        xmid = x1 + ((x2 - x1) >> 12) * p12
        if bit: x2 = xmid
        else: x1 = xmid + 1
        while not ((x1 ^ x2) & 0xFF000000):
            out.append(x2 >> 24)
            x1 = (x1 << 8) & 0xFFFFFFFF; x2 = ((x2 << 8) & 0xFFFFFFFF) | 255
        st["x1"], st["x2"] = x1, x2
        return bit

    def finish():
        out.extend(st["x1"].to_bytes(4, "big"))
        return bytes(out).rstrip(b"\0")  # decoder pads with zeros
    return enc, finish


def _decoder(buf):
    buf = buf + bytes(4)
    st = {"x1": 0, "x2": 0xFFFFFFFF, "x": int.from_bytes(buf[:4], "big"), "pos": 4}

    def dec(p12, _):
        x1, x2, x = st["x1"], st["x2"], st["x"]
        xmid = x1 + ((x2 - x1) >> 12) * p12
        bit = 1 if x <= xmid else 0
        if bit: x2 = xmid
        else: x1 = xmid + 1
        while not ((x1 ^ x2) & 0xFF000000):
            x1 = (x1 << 8) & 0xFFFFFFFF; x2 = ((x2 << 8) & 0xFFFFFFFF) | 255
            b = buf[st["pos"]] if st["pos"] < len(buf) else 0
            st["pos"] += 1
            x = ((x << 8) & 0xFFFFFFFF) | b
        st["x1"], st["x2"], st["x"] = x1, x2, x
        return bit
    return dec


# ---- bytes mode -------------------------------------------------------------
ORDERS = (1, 2, 3, 4, 6)


def _bytes_model(L, src):
    buf = bytearray(L)
    def ctx_of(i):
        # int keys: hash() of ints is deterministic across processes (bytes/str hashes are salted)
        return [0] + [hash((k, int.from_bytes(buf[max(0, i - k):i], "big"))) for k in ORDERS]
    def put(i, b): buf[i] = b
    sym_of = (lambda i: src[i]) if src is not None else (lambda i: 0)
    return ctx_of, sym_of, put, buf, 1 + len(ORDERS)


# ---- image mode ------------------------------------------------------------
def _image_model(L, width, src):
    pix = bytearray(L); err = [0] * L; med = [0]
    q = lambda s: -12 if s < -12 else (12 if s > 12 else s)

    def ctx_of(i):
        ch = i % 3; x = (i // 3) % width; up = i - 3 * width
        a = pix[i - 3] if x else (pix[up] if up >= 0 else 0)
        b = pix[up] if up >= 0 else a
        c = pix[up - 3] if (up >= 0 and x) else b
        med[0] = min(a, b) if c >= max(a, b) else (max(a, b) if c <= min(a, b) else a + b - c)
        ea = q(err[i - 3]) if x else 0
        eb = q(err[up]) if up >= 0 else 0
        ep = q(err[i - 1]) if ch else 99
        g = (abs(a - c) + abs(b - c)).bit_length()
        return [ch, hash((1, ch, ea)), hash((2, ch, eb)), hash((3, ch, ep)),
                hash((4, ch, ea, eb)), hash((5, ch, ep, g)), hash((6, ch, ep, ea))]

    def sym_of(i):
        return (src[i] - med[0]) & 255 if src is not None else 0

    def put(i, r):
        pix[i] = (med[0] + r) & 255
        e = pix[i] - med[0]; err[i] = e
    return ctx_of, sym_of, put, pix, 7


def encode(data: bytes, mode="bytes", width=0) -> tuple[int, int, int]:
    """Returns (N, k, L): the data is the fraction N / 256^k decoded with the model."""
    L = len(data)
    ctx_of, sym_of, put, _, n = _image_model(L, width, data) if mode == "image" else _bytes_model(L, data)
    enc, finish = _encoder()
    _run(L, ctx_of, sym_of, put, enc, n)
    out = finish()
    return int.from_bytes(out, "big"), len(out), L


def decode(N: int, k: int, L: int, mode="bytes", width=0) -> bytes:
    ctx_of, sym_of, put, buf, n = _image_model(L, width, None) if mode == "image" else _bytes_model(L, None)
    _run(L, ctx_of, sym_of, put, _decoder(N.to_bytes(k, "big")), n)
    return bytes(buf)


if __name__ == "__main__":
    import os
    for d in (b"", b"a", b"hello hello hello", os.urandom(500), b"\0" * 300, bytes(range(256)) * 3):
        assert decode(*encode(d)) == d
    img = bytes((x * 7 + y * 3 + c * 50) & 255 for y in range(20) for x in range(17) for c in range(3))
    assert decode(*encode(img, "image", 17), "image", 17) == img
    print("self-check ok")
