"""zlib baseline (C library via Python, streamed in 1 MB chunks). Usage: zlib_bench.py FILE..."""
import os, sys, time, zlib

CHUNK = 1 << 20
for path in sys.argv[1:]:
    size = os.path.getsize(path)
    for level in (6, 9):
        t0 = time.perf_counter()
        co, out, parts = zlib.compressobj(level), 0, []
        with open(path, "rb") as f:
            while b := f.read(CHUNK):
                parts.append(co.compress(b))
        parts.append(co.flush())
        t1 = time.perf_counter()
        out = sum(map(len, parts))
        do, ok = zlib.decompressobj(), True
        with open(path, "rb") as f:
            for p in parts:
                d = do.decompress(p)
                if d != f.read(len(d)):
                    ok = False
            ok = ok and f.read(1) == b""
        t2 = time.perf_counter()
        print(f"{os.path.basename(path):26} zlib-{level} {size:>11} {out:>11} {out / size:7.3f} "
              f"{t1 - t0:8.2f} {t2 - t1:8.2f} {size / 1e6 / (t1 - t0):8.1f}  {'rt-ok' if ok else 'RT-FAIL'}", flush=True)
