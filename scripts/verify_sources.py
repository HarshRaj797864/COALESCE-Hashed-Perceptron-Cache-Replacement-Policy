#!/usr/bin/env python3
"""Validation round, 2026-10-17: is every file the server ran a committed version?

    scripts/verify_sources.py COLLECT_DIR      (an unpacked audit: it reads sources.md5 and bins.txt)

sources.md5 lines: "<tree> <md5>  <path>", tree = the main tree's directory
name, c0_build, diag_build, or home (the runner scripts in ~, which are
scripts/<name> in the repository). For every file it finds the commits whose
version of that path has the same md5 and prints the newest, so it says which
commit each tree was built from -- or NOT IN GIT HISTORY, which means a file
that ran was never committed.
Also checks that each frozen binary's name carries the first 8 hex digits of
its md5 (champsim_b3v4_69ebdcce and the like).
"""
import collections
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def git(*a):
    return subprocess.run(['git', '-C', ROOT, *a], capture_output=True, check=False).stdout


def versions(path):
    """{md5: [(commit date, short hash), ...]} for every committed version of `path`."""
    out = collections.defaultdict(list)
    for line in git('log', '--format=%h %cs', '--', path).decode().splitlines():
        h, date = line.split()
        blob = git('show', f'{h}:{path}')
        if blob:
            out[hashlib.md5(blob).hexdigest()].append((date, h))
    return out


def main():
    root = sys.argv[1]
    by_tree = collections.defaultdict(list)
    for line in open(os.path.join(root, 'sources.md5')):
        p = line.split()
        if len(p) == 2 and p[1] == 'MISSING':
            print(f'{p[0]}: tree missing on the server')
            continue
        tree, md5, path = p[0], p[1], p[2]
        repo_path = f'scripts/{path}' if tree == 'home' else path
        by_tree[tree].append((repo_path, md5))
    cache = {}
    for tree, files in sorted(by_tree.items()):
        newest = collections.Counter()
        missing = []
        for repo_path, md5 in files:
            if repo_path not in cache:
                cache[repo_path] = versions(repo_path)
            v = cache[repo_path]
            if md5 in v:
                newest[max(v[md5])] += 1
            else:
                missing.append(repo_path)
        print(f'== {tree}: {len(files)} files; {len(missing)} not in git history')
        for (date, h), n in sorted(newest.items(), reverse=True)[:6]:
            print(f'   {n:4d} file(s) last changed in {h} ({date})')
        for m in missing:
            if not os.path.exists(os.path.join(ROOT, m)):
                print(f'   NOT IN THE REPOSITORY: {m}')
            else:
                print(f'   NOT IN GIT HISTORY: {m}')
    print()
    print('== frozen binaries: does the name carry the md5? ==')
    for line in open(os.path.join(root, 'bins.txt')):
        m = re.match(r'(\S+) (\S+) md5=([0-9a-f]+)', line)
        if not m:
            continue
        name = os.path.basename(m.group(2))
        tag = re.search(r'_([0-9a-f]{8})$', name)
        if tag and not re.fullmatch(r'20\d{6}', tag.group(1)):   # a date, or a 7-digit commit hash, is not an md5 tag
            ok = m.group(3).startswith(tag.group(1))
            print(f'   {"ok      " if ok else "MISMATCH"} {m.group(1)}/{m.group(2)} md5 {m.group(3)[:12]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
