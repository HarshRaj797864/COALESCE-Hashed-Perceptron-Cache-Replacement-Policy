#!/usr/bin/env python3
"""Step 5's job lines for sync_server.sh VARIANT=pol (policy_rerun_design_2026-10-19.md).

    scripts/policy_jobs.py > jobs.txt        (171 lines, the 16-core jobs first)

A line: suffix | workload | cores | scaled | warm-up | measured | traces |
policy | regime | LLC MSHRs (empty = 16). Trees phaseA_b3_p2_<suffix>.
"""
POLICIES = ['lru', 'srrip', 'drrip', 'ship', 'hawkeye', 'mockingjay', 'random', 'srrip_bias', 'coalesce']
WU, SIM = 50_000_000, 100_000_000

# (traces, workload, cores, regimes, LLC MSHRs, sizes), longest first
SETS = [
    ('canneal16', 'canneal', 16, ['shared'], '', [0, 1]),
    ('canneal8', 'canneal', 8, ['shared', 'private'], '', [0, 1]),
    ('canneal4', 'canneal', 4, ['shared', 'private'], '', [0, 1]),
    ('barnesstd', 'barnes', 4, ['shared', 'private'], '', [0, 1]),
    ('ocean4', 'ocean', 4, ['shared', 'private'], '', [0, 1]),
    ('canneal4', 'canneal', 4, ['shared'], '64', [0]),
]


def main():
    n = 0
    for traces, wl, cores, regimes, mshr, sizes in SETS:
        for scaled in sizes:
            suffix = f'{wl if traces != "barnesstd" else "barnesstd"}{cores}' + ('_scaled' if scaled else '') + (f'_mshr{mshr}' if mshr else '')
            for rg in regimes:
                for pol in POLICIES:
                    # no empty last field: the chain turns '|' into spaces for
                    # xargs -L 1, which joins a line ending in a blank to the next
                    print(f'{suffix}|{wl}|{cores}|{scaled}|{WU}|{SIM}|{traces}|{pol}|{rg}' + (f'|{mshr}' if mshr else ''))
                    n += 1
    assert n == 171, n


if __name__ == '__main__':
    main()
