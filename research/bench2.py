"""Compare: plain fraction (fracenc) vs model-guided fraction (modelfrac) vs zlib/lzma.
Usage: python3 bench2.py 10000 100000 1000000"""
import glob, lzma, sys, time, zlib
from bench import photo_like, png
import modelfrac


def datasets(size):
    text = b"".join(open(f, "rb").read() for f in sorted(glob.glob("/usr/lib/python3*/**/*.py", recursive=True)))
    w, h, rgb = photo_like(size)
    yield "text/code", text[:size], "bytes", 0
    yield "raw image (bytes)", rgb, "bytes", 0
    yield "raw image (image)", rgb, "image", w
    yield "PNG of that image", png(w, h, rgb), "bytes", 0


if __name__ == "__main__":
    print(f"{'data':19}{'size':>9}{'plain frac':>11}{'model frac':>11}{'ratio':>7}{'zlib':>9}{'lzma':>9}{'enc s':>7}{'dec s':>7} ok")
    for size in map(int, sys.argv[1:] or ["10000"]):
        for name, data, mode, w in datasets(size):
            t0 = time.time(); N, k, L = modelfrac.encode(data, mode, w); t1 = time.time()
            ok = modelfrac.decode(N, k, L, mode, w) == data; t2 = time.time()
            print(f"{name:19}{len(data):>9}{len(data):>11}{k:>11}{k / len(data):>7.3f}"
                  f"{len(zlib.compress(data, 9)):>9}{len(lzma.compress(data, preset=9)):>9}"
                  f"{t1 - t0:>7.1f}{t2 - t1:>7.1f} {ok}", flush=True)
