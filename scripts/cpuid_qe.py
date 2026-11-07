#!/usr/bin/env python3
"""QE / QK: does cpuid_dump, run under an emulation of gem5's CPUID, print what
gem5 answers? (bench/policy_sanity/stream_fix_design_2026-11-02.md, amendment 2)

    cpuid_qe.py FILE DUMP

FILE is gem5.cpuid as streamfix_server.sh assembles it: the header line
"# cpuid_dump: ...", "CPUID leaf subleaf eax ebx ecx edx" lines (hex), and
"# gem5 aborts: leaf L subleaf S" for each pair gem5 cannot answer (gem5 25.1
asserts on leaf 0xd past its two subleaves). DUMP is cpuid_dump's output, no
arguments, under the counter or the tracer with -cpuid FILE.

Holds when
  1. DUMP's header line equals FILE's (vendor, largest basic and extended leaf),
  2. every CPUID line of FILE is in DUMP, identically,
  3. DUMP's leaf/subleaf pairs are exactly FILE's pairs plus the pairs gem5
     aborts on (a line gem5 never printed is accepted only where gem5 aborts).
Exit 0 when it holds, 1 otherwise; one line of verdict, then the misses.
"""
import re
import sys


def read(path):
    head, lines, aborts = None, {}, set()
    for ln in open(path):
        ln = ln.strip()
        if ln.startswith('# cpuid_dump:') and head is None:
            head = ln
            continue
        m = re.match(r'# gem5 aborts: leaf ([0-9a-f]+) subleaf ([0-9a-f]+)', ln)
        if m:
            aborts.add((int(m.group(1), 16), int(m.group(2), 16)))
            continue
        p = ln.split()
        if len(p) == 7 and p[0] == 'CPUID':
            key = (int(p[1], 16), int(p[2], 16))
            if key in lines and lines[key] != ln:
                lines[key] = None   # one pair printed two ways: never equal to anything
            else:
                lines.setdefault(key, ln)
    return head, lines, aborts


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    fhead, flines, aborts = read(sys.argv[1])
    dhead, dlines, _ = read(sys.argv[2])
    bad = []
    if fhead is None or fhead != dhead:
        bad.append(f'header: gem5 {fhead!r}, dump {dhead!r}')
    for key, ln in sorted(flines.items()):
        if dlines.get(key) != ln:
            bad.append(f'{key[0]:x} {key[1]:x}: gem5 {ln!r}, dump {dlines.get(key)!r}')
    for key in sorted(set(dlines) - set(flines)):
        if key not in aborts:
            bad.append(f'{key[0]:x} {key[1]:x}: in the dump ({dlines[key]!r}), not answered by gem5 and not a pair gem5 aborts on')
    for key in sorted(aborts - set(dlines)):
        bad.append(f'{key[0]:x} {key[1]:x}: gem5 aborts on it, the dump never asked it')
    for key in sorted(aborts & set(flines)):
        bad.append(f'{key[0]:x} {key[1]:x}: both answered and aborted in FILE')
    if not flines:
        bad.append('FILE has no CPUID line')
    if bad:
        print(f'FAILS: {len(bad)} misses ({len(flines)} lines answered by gem5, {len(aborts)} pairs gem5 aborts on)')
        for b in bad[:40]:
            print('  ', b)
        return 1
    print(f'holds: {len(flines)} lines equal, the {len(set(dlines) - set(flines))} other pairs the dump asked are the {len(aborts)} gem5 aborts on')
    return 0


if __name__ == '__main__':
    sys.exit(main())
