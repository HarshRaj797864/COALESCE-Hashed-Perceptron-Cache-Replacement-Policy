import sys, struct
FMT, SZ = "<QBB2B4B2Q4Q", 64
skip = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000
f = sys.stdin.buffer
n = skip * SZ
while n > 0:
    c = f.read(min(n, 1 << 20))
    if not c: break
    n -= len(c)
tot = mem = 0
for _ in range(200000):
    r = f.read(SZ)
    if len(r) < SZ: break
    v = struct.unpack(FMT, r)
    tot += 1
    if any(v[9:15]): mem += 1
print(f"  {tot} records sampled, {100*mem/tot:.1f}% carry memory operands" if tot else "  no records")
