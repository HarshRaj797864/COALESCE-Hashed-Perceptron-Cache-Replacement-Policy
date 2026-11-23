#!/usr/bin/env python3
"""Part B's sizing records as one committed text file, from the pulled
records (scripts/partB_all.sh pull -> simulator/results/partB/).

    partB_sizing_rows.py rows  DIR > bench/policy_sanity/partB_sizing_rows_vN.txt
    partB_sizing_rows.py table ROWS      the table of the results note, from the rows file alone

rows: per key, the runner's record files (one line each), every thread's
instruction count and the number of thread starts from the chosen rung's
probe file, the count at the run's first pthread_cond_broadcast, and the
key's sizing log verbatim (every rung tried and why it was or was not
chosen). Reads nothing else; computes nothing but the counts named.
"""
import os
import sys

FILES = ['CHOSEN', 'NTHR', 'NCPU', 'SKIP', 'MIN', 'BELOW', 'MD5', 'PROGS', 'JOBS', 'GEM5', 'FAILED_E3']


def keys(d):
    ks = [k for k in os.listdir(d) if os.path.isdir(os.path.join(d, k)) and k.rsplit('_', 1)[-1] in ('8', '16')]
    return sorted(ks, key=lambda k: (int(k.rsplit('_', 1)[1]), k))


def rows(d):
    print(f'# Part B sizing records; keys: {len(keys(d))}')
    for k in keys(d):
        kd = os.path.join(d, k)
        for f in FILES:
            p = os.path.join(kd, f)
            if os.path.isfile(p):
                for line in open(p).read().rstrip('\n').split('\n'):
                    print(f'{k}|{f}|{line}')
        p = os.path.join(kd, 'probe_chosen.txt')
        if os.path.isfile(p):
            starts = 0
            first_bc = None
            for line in open(p):
                w = line.split()
                if not w:
                    continue
                if w[0] == 'START':
                    starts += 1
                elif w[0] == 'TOTAL':
                    print(f'{k}|TOTAL|{w[1]}|{w[2]}')
                elif w[0] == 'CALL' and w[1] == 'broadcast' and first_bc is None:
                    first_bc = (w[2], w[4])
            print(f'{k}|STARTS|{starts}')
            if first_bc:
                print(f'{k}|FIRST_BROADCAST|{first_bc[0]}|{first_bc[1]}')
        p = os.path.join(kd, 'size.log')
        if os.path.isfile(p):
            for line in open(p).read().rstrip('\n').split('\n'):
                print(f'{k}|LOG|{line}')


def table(path):
    rec = {}
    for line in open(path):
        if line.startswith('#'):
            continue
        w = line.rstrip('\n').split('|')
        rec.setdefault(w[0], {}).setdefault(w[1], []).append(w[2:])
    print('| key | rung | threads started | gem5 CPUs | least traced thread | skip | rungs tried |')
    print('|---|---|---|---|---|---|---|')
    for k, r in rec.items():
        if 'STARTS' not in r:      # no probe file: failed E3 on every rung, or a key that is not sized (canneal_16)
            why = r['FAILED_E3'][0][0] if 'FAILED_E3' in r else 'not sized: traced already'
            print(f'| {k} | -- | -- | {r.get("NCPU", [["--"]])[0][0]} | -- | -- | {why} |')
            continue
        tried = sum(1 for x in r.get('LOG', []) if x and x[0].startswith('   rung '))
        below = ' BELOW' if 'BELOW' in r else ''
        print(f'| {k} | {r["CHOSEN"][0][0]} | {r["STARTS"][0][0]} | {r["NCPU"][0][0]} | '
              f'{int(r["MIN"][0][0]) / 1e6:.0f} M{below} | {int(r["SKIP"][0][0]) // 1000000} M | {tried} |')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'rows':
        rows(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == 'table':
        table(sys.argv[2])
    else:
        sys.exit(__doc__)
