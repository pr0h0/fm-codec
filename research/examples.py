"""Print what both encoders actually output for a few inputs."""
import fracenc, modelfrac


def short(n: int, keep=30) -> str:
    s = str(n)
    return s if len(s) <= 2 * keep else f"{s[:keep]}…{s[-10:]} ({len(s)} digits)"


inputs = [
    b"hello",
    b"Hello, World!",
    b"the cat sat on the mat. the cat sat on the mat. the cat sat on the mat.",
    b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    open("fracenc.py", "rb").read(),
]
for data in inputs:
    label = repr(data[:50])[2:-1] + ("…" if len(data) > 50 else "")
    N, D, L = fracenc.encode(data)
    assert fracenc.decode(N, D, L) == data
    M, k, L2 = modelfrac.encode(data)
    assert modelfrac.decode(M, k, L2) == data
    print(f"input  ({len(data)} bytes): {label}")
    print(f"  plain fraction  N/D = {short(N)} / {short(D)}   L={L}"
          f"   -> {(N.bit_length() + D.bit_length() + 7) // 8} bytes")
    print(f"  model fraction  N/256^k = {short(M)} / 256^{k}   L={L2}   -> {k} bytes")
    print()
