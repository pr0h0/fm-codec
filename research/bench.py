"""Benchmark fracenc on several data types and sizes.  Usage: python3 bench.py 1000 10000 100000"""
import glob, math, os, random, struct, sys, time, zlib
from fracenc import encode, decode


def png(w, h, rgb: bytes) -> bytes:
    """Minimal RGB PNG writer (stdlib only) so the test image can be viewed."""
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def photo_like(nbytes: int) -> tuple[int, int, bytes]:
    """Smooth gradients + shapes + sensor noise, roughly photo statistics."""
    w = int(math.sqrt(nbytes / 3 * 4 / 3)); h = nbytes // 3 // w
    rnd = random.Random(1)
    px = bytearray()
    for y in range(h):
        for x in range(w):
            sky = y < h * 0.55 + 30 * math.sin(x / 40)
            r, g, b = (90 + y // 4, 140 + y // 5, 230) if sky else (60 + x % 37, 120 - y // 8, 40)
            if (x - w * .7) ** 2 + (y - h * .25) ** 2 < (h * .1) ** 2:
                r, g, b = 250, 220, 120
            n = rnd.randint(-6, 6)
            px += bytes(max(0, min(255, c + n)) for c in (r, g, b))
    return w, h, bytes(px)


def datasets(size: int):
    text = b"".join(open(f, "rb").read() for f in sorted(glob.glob("/usr/lib/python3*/[a-k]*.py")))
    w, h, rgb = photo_like(size)
    pngfile = png(*photo_like(size * 4)[:2], photo_like(size * 4)[2])  # PNG ~ compressed image
    yield "random", os.urandom(size)
    yield "english/code text", text[:size]
    yield "raw image pixels", rgb[:size]
    yield "PNG file bytes", pngfile[:size]
    yield "periodic (abc...)", (b"abcdefghij" * size)[:size]


if __name__ == "__main__":
    print(f"{'data':20}{'size':>10}{'N+D bytes':>12}{'ratio':>8}{'zlib':>10}{'enc s':>8}{'dec s':>8}  ok")
    for size in map(int, sys.argv[1:] or ["1000", "10000"]):
        for name, data in datasets(size):
            t0 = time.time(); N, D, L = encode(data); t1 = time.time()
            ok = decode(N, D, L) == data; t2 = time.time()
            nd = (N.bit_length() + D.bit_length() + 7) // 8
            print(f"{name:20}{len(data):>10}{nd:>12}{nd / len(data):>8.3f}{len(zlib.compress(data, 9)):>10}"
                  f"{t1 - t0:>8.2f}{t2 - t1:>8.2f}  {ok}", flush=True)
