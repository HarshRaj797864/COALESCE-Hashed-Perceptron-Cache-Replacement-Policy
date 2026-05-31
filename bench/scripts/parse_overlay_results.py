#!/usr/bin/env python3
"""Parse ChampSim run logs from the V1..V6 synth-overlay matrix into a CSV/MD table.

Extracts the smoking-gun counters and per-CPU IPCs. Run after
bench/scripts/run_synth_matrix.sh, pointing at the logs directory.

Usage:
  parse_overlay_results.py path/to/logs/
  parse_overlay_results.py path/to/logs/ --csv out.csv
  parse_overlay_results.py path/to/logs/ --md  out.md
"""
import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict


def parse_log(path):
    """Pull the counters and per-CPU IPC out of one ChampSim output log."""
    out = {
        'log': os.path.basename(path),
        'aliased_fills': 0,
        'llc_invalidations': 0,
        'llc_other_sharer_events': 0,
        'llc_sharer_hist': {},   # bin -> count
        'ipc_per_cpu': {},       # cpu -> IPC
        'max_cycles': 0,
    }
    with open(path, errors='replace') as f:
        for line in f:
            line = line.strip()

            m = re.match(r'VMEM ALIASED FILLS .*: *(\d+)', line)
            if m:
                out['aliased_fills'] = int(m.group(1))

            m = re.match(r'^LLC COHERENCE INVALIDATIONS: *(\d+)', line)
            if m:
                out['llc_invalidations'] = int(m.group(1))

            m = re.match(r'^LLC COHERENCE WRITE-HIT OTHER-SHARER EVENTS: *(\d+)', line)
            if m:
                out['llc_other_sharer_events'] = int(m.group(1))

            # LLC SHARER HIST[ 2]:        12345  ( 0.123%)
            m = re.match(r'^LLC SHARER HIST\[ *(\d+) *\]: *(\d+) ', line)
            if m:
                out['llc_sharer_hist'][int(m.group(1))] = int(m.group(2))

            # CPU 0 cumulative IPC: 1.234 instructions: ... cycles: 12345
            m = re.match(r'^CPU (\d+) cumulative IPC: *([\d.]+) .* cycles: *(\d+)', line)
            if m:
                cpu, ipc, cyc = int(m.group(1)), float(m.group(2)), int(m.group(3))
                out['ipc_per_cpu'][cpu] = ipc
                out['max_cycles'] = max(out['max_cycles'], cyc)
    return out


def hist_summary(h):
    """Render the sharer-count histogram as 'bin[k]=x.xxx%' for the top non-empty bins."""
    if not h:
        return '-'
    total = sum(h.values())
    if total == 0:
        return '-'
    items = sorted(h.items(), key=lambda kv: kv[1], reverse=True)[:4]
    return ' '.join(f'b[{k}]={100.0*v/total:.3f}%' for k, v in items)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('logdir')
    ap.add_argument('--csv', default=None, help='write CSV here')
    ap.add_argument('--md', default=None, help='write markdown table here')
    args = ap.parse_args()

    logs = sorted(glob.glob(os.path.join(args.logdir, '*.log')))
    if not logs:
        print(f'no *.log files in {args.logdir}', file=sys.stderr)
        sys.exit(1)

    rows = [parse_log(p) for p in logs]

    headers = ['run', 'max_cycles', 'aliased_fills', 'llc_invals',
               'llc_other_share_evs', 'sharer_hist_top4', 'mean_ipc']

    def to_row(r):
        ipcs = list(r['ipc_per_cpu'].values())
        mean_ipc = sum(ipcs) / len(ipcs) if ipcs else 0.0
        return [
            os.path.splitext(r['log'])[0],
            r['max_cycles'],
            r['aliased_fills'],
            r['llc_invalidations'],
            r['llc_other_sharer_events'],
            hist_summary(r['llc_sharer_hist']),
            f'{mean_ipc:.4f}',
        ]

    # stdout table
    print('  '.join(f'{h:>22}' for h in headers))
    for r in rows:
        print('  '.join(f'{c!s:>22}' for c in to_row(r)))

    if args.csv:
        with open(args.csv, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(headers)
            for r in rows:
                w.writerow(to_row(r))
        print(f'\ncsv -> {args.csv}', file=sys.stderr)

    if args.md:
        with open(args.md, 'w') as f:
            f.write('| ' + ' | '.join(headers) + ' |\n')
            f.write('|' + '|'.join(['---'] * len(headers)) + '|\n')
            for r in rows:
                f.write('| ' + ' | '.join(str(c) for c in to_row(r)) + ' |\n')
        print(f'md  -> {args.md}', file=sys.stderr)


if __name__ == '__main__':
    main()
