"""Summarise the labelled Ghidra listing: per function, callees, callers,
A6-relative globals read/written, absolute RAM addresses and custom registers."""
import re, sys, collections
lst = open(sys.argv[1]).read().split('\n')
func = None
calls = collections.defaultdict(set); callers = collections.defaultdict(set)
glob = collections.defaultdict(set); absr = collections.defaultdict(set); size = collections.Counter()
for l in lst:
    m = re.match(r';=+ (\S+) =+', l)
    if m: func = m.group(1); continue
    m = re.match(r'([0-9a-f]{8})  (.*)', l)
    if not m or func is None or 'data' in l: continue
    ins = m.group(2); size[func] += 1
    for t in re.findall(r'(?:bsr|jsr)\.?\w* 0x([0-9a-f]+)', ins):
        calls[func].add(int(t, 16))
    for o in re.findall(r'\((-?0x[0-9a-f]+),A6\)', ins): glob[func].add(o)
    if re.search(r'[ ,]\(A6\)', ins): glob[func].add('0x0')
    for a in re.findall(r'\(0x([0-9a-f]{5,6})\)\.[lw]', ins):
        v = int(a, 16)
        if 0x60000 <= v < 0x80000 or 0xdff000 <= v: absr[func].add(hex(v))
names = {}
for l in lst:
    m = re.match(r';=+ (\S+) =+', l)
for f in sorted(size):
    print(f"{f}: {size[f]} instr; calls {sorted(hex(c) for c in calls[f])}; A6 {sorted(glob[f], key=lambda x:int(x,16))}; abs {sorted(absr[f])}")
