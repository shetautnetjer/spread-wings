#!/usr/bin/env python3
"""Random changes to a copy of a repo. After each batch, `update` on the
graph kept from before must leave the graph `index` builds from the same
files (graph_dump.py prints both without row numbers), and `overview` must
say the same of both.

  tests/random_changes.py <repo> <workdir> [--sw bin/spread-wings] [--rounds N] [--seed S] [--per K]
                                           [--settle] [--no-overview] [--only KIND]

The repo is copied into <workdir>/repo (which is emptied first) and only the
copy is changed: lines added and removed, functions appended and renamed,
imports dropped and borrowed from other files, files copied, moved, swapped
and deleted, folders moved, __init__.py added and removed, new folders at
the top. Nothing of the repo is run. --per: up to that many changes a round.
--settle: wait four seconds after copying, so that file times are trusted
from the first round. --no-overview: skip `overview`, which is slow on a
very large graph. On the first difference both dumps are left in <workdir>
and the exit status is 1. Needs rsync.
"""
import argparse, json, os, random, shutil, sqlite3, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument('repo'); ap.add_argument('work')
ap.add_argument('--sw', default=os.path.join(HERE, '..', 'bin', 'spread-wings'))
ap.add_argument('--rounds', type=int, default=20)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--per', type=int, default=3)
ap.add_argument('--settle', action='store_true')
ap.add_argument('--only', default='')
ap.add_argument('--no-overview', action='store_true')
a = ap.parse_args()
a.dump = os.path.join(HERE, 'graph_dump.py')
rng = random.Random(a.seed)
repo = os.path.join(a.work, 'repo')
g, f = os.path.join(a.work, 'g.db'), os.path.join(a.work, 'f.db')
shutil.rmtree(a.work, ignore_errors=True)
os.makedirs(a.work)
subprocess.check_call(['rsync', '-a', '--exclude', '.git', '--exclude', 'node_modules', '--exclude', 'target',
                       '--exclude', 'dist', '--exclude', 'build', a.repo.rstrip('/') + '/', repo + '/'])
if a.settle:
    time.sleep(4)


def run(*cmd):
    t = time.time()
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print('FAILED:', ' '.join(cmd), out.stderr[-2000:], file=sys.stderr)
        sys.exit(2)
    return out.stdout, time.time() - t


def dump(db):
    return run('python3', a.dump, '--ord', db)[0]


def files():
    con = sqlite3.connect(f'file:{g}?mode=ro', uri=True)
    rows = con.execute('SELECT path, lang FROM files').fetchall()
    names = [r[0] for r in con.execute(
        "SELECT name FROM symbols WHERE kind IN ('function','class','struct') AND length(name) > 2 ORDER BY random() LIMIT 400")]
    con.close()
    return rows, names


def read(p):
    with open(os.path.join(repo, p), encoding='utf-8', errors='surrogateescape') as fh:
        return fh.read()


def write(p, text):
    full = os.path.join(repo, p)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write(text)


uniq = [0]


def fresh(prefix='zz'):
    uniq[0] += 1
    return f'{prefix}_{a.seed}_{uniq[0]}'


def fn_text(lang, name, callee):
    if lang == 'python':
        return f'\n\ndef {name}(a, b):\n    x = {callee}(a)\n    return x.get(b)\n'
    if lang == 'rust':
        return f'\n\npub fn {name}(a: i32) -> i32 {{\n    let x = {callee}(a);\n    x\n}}\n'
    return f'\n\nexport function {name}(a, b) {{\n  const x = {callee}(a);\n  return x.map(b);\n}}\n'


def is_import(line, lang):
    s = line.lstrip()
    if lang == 'python':
        return s.startswith('import ') or s.startswith('from ')
    if lang == 'rust':
        return s.startswith('use ') or s.startswith('mod ') or s.startswith('pub mod ')
    return s.startswith('import ') or s.startswith('export ') and ' from ' in s


def mutate(rows, names):
    kinds = ['body', 'body', 'body', 'body', 'append_def', 'append_def', 'append_common', 'delete_chunk',
             'delete_file', 'copy_file', 'rename_file', 'touch', 'rewrite', 'drop_import', 'borrow_import',
             'rename_ident', 'new_top_dir', 'py_init', 'move_dir', 'swap']
    kind = a.only or rng.choice(kinds)
    live = [(p, l) for p, l in rows if os.path.isfile(os.path.join(repo, p))]
    if not live:
        return 'nothing left'
    p, lang = rng.choice(live)
    ext = os.path.splitext(p)[1]
    if kind == 'body':
        lines = read(p).split('\n')
        at = rng.randrange(len(lines) + 1)
        lines.insert(at, '# note' if lang == 'python' else '// note')
        write(p, '\n'.join(lines))
    elif kind == 'append_def':
        write(p, read(p) + fn_text(lang, fresh(), rng.choice(names) if names else 'len'))
    elif kind == 'append_common':
        write(p, read(p) + fn_text(lang, rng.choice(names) if names else 'run', rng.choice(names) if names else 'len'))
    elif kind == 'delete_chunk':
        lines = read(p).split('\n')
        if len(lines) > 3:
            at = rng.randrange(len(lines))
            del lines[at:at + rng.randint(1, 15)]
            write(p, '\n'.join(lines))
    elif kind == 'delete_file':
        os.remove(os.path.join(repo, p))
    elif kind == 'copy_file':
        q = os.path.join(os.path.dirname(p), fresh('copy') + ext)
        write(q, read(p))
        p = f'{p} -> {q}'
    elif kind == 'rename_file':
        q = os.path.join(os.path.dirname(p), fresh('moved') + ext)
        os.rename(os.path.join(repo, p), os.path.join(repo, q))
        p = f'{p} -> {q}'
    elif kind == 'touch':
        os.utime(os.path.join(repo, p))
    elif kind == 'rewrite':
        write(p, read(p))
    elif kind == 'drop_import':
        lines = read(p).split('\n')
        idx = [i for i, l in enumerate(lines) if is_import(l, lang)]
        if idx:
            del lines[rng.choice(idx)]
            write(p, '\n'.join(lines))
    elif kind == 'borrow_import':
        others = [(q, l) for q, l in live if l == lang and q != p]
        if others:
            q, _ = rng.choice(others)
            imps = [l for l in read(q).split('\n') if is_import(l, lang) and not l.rstrip().endswith(('{', '(', ','))]
            if imps:
                write(p, rng.choice(imps) + '\n' + read(p))
    elif kind == 'rename_ident':
        con = sqlite3.connect(f'file:{g}?mode=ro', uri=True)
        got = con.execute("SELECT s.name FROM symbols s JOIN files f ON f.id = s.file_id WHERE f.path = ? AND length(s.name) > 3 "
                          "ORDER BY random() LIMIT 1", (p,)).fetchone()
        con.close()
        if got:
            write(p, read(p).replace(got[0], got[0] + '_zz'))
            p = f'{p} ({got[0]})'
    elif kind == 'new_top_dir':
        q = os.path.join(fresh('top'), os.path.basename(p))
        write(q, read(p))
        p = f'{p} -> {q}'
    elif kind == 'py_init':
        d = os.path.dirname(p)
        if lang == 'python' and d:
            init = os.path.join(repo, d, '__init__.py')
            if os.path.exists(init):
                os.remove(init)
            else:
                open(init, 'w').close()
            p = d + '/__init__.py'
    elif kind == 'move_dir':
        d = os.path.dirname(p)
        if d and os.path.isdir(os.path.join(repo, d)):
            q = d + '_' + fresh('mv')
            os.rename(os.path.join(repo, d), os.path.join(repo, q))
            p = f'{d} -> {q}'
    elif kind == 'swap':
        others = [(q, l) for q, l in live if l == lang and q != p]
        if others:
            q, _ = rng.choice(others)
            tp, tq = read(p), read(q)
            write(p, tq)
            write(q, tp)
            p = f'{p} <-> {q}'
    return f'{kind}: {p}'


out, t = run(a.sw, 'index', repo, g)
print(f'index: {t:.2f} s  {out.strip().split(";")[-1].strip()}')
u, t = run(a.sw, 'update', repo, g)
d = json.loads(u)
print(f'update, nothing changed: {t:.2f} s, looked at {d["looked_at"]} of {d["files"]}')
stats = []
for r in range(a.rounds):
    rows, names = files()
    log = [mutate(rows, names) for _ in range(rng.randint(1, a.per))]
    u, tu = run(a.sw, 'update', repo, g)
    d = json.loads(u)
    _, tf = run(a.sw, 'index', repo, f)
    du, df = dump(g), dump(f)
    same = du == df
    same_ov = True
    if not a.no_overview:
        ov_u = json.loads(run(a.sw, 'overview', g)[0]); ov_f = json.loads(run(a.sw, 'overview', f)[0])
        same_ov = ov_u == ov_f
    tied = d.get('calls_tied_again', -1)
    print(f'{r + 1:3} {"same" if same and same_ov else "DIFFERENT"}  update {tu:6.2f} s  index {tf:6.2f} s  '
          f'changed {len(d.get("changed", []))} added {len(d.get("added", []))} removed {len(d.get("removed", []))}  '
          f'calls tied again {tied} of {d.get("calls", 0)}{" (all)" if d.get("all_calls_tied_again") else ""}'
          f'{" BUILT WHOLE: " + d.get("why", "") if d.get("built_whole") else ""}  | ' + '; '.join(log))
    stats.append((tu, tf))
    if not (same and same_ov):
        open(os.path.join(a.work, 'update.dump'), 'w').write(du)
        open(os.path.join(a.work, 'index.dump'), 'w').write(df)
        if not same:
            ul, fl = set(du.split('\n')), set(df.split('\n'))
            only_u = sorted(ul - fl); only_f = sorted(fl - ul)
            print(f'  only after update: {len(only_u)} lines, only after index: {len(only_f)} lines')
            for l in only_u[:12]: print('  U', l[:230])
            for l in only_f[:12]: print('  I', l[:230])
        else:
            print('  the graphs are the same; `overview` is not')
        sys.exit(1)
tu = sum(s[0] for s in stats); tf = sum(s[1] for s in stats)
print(f'all {len(stats)} rounds the same; update {tu:.1f} s in all, index {tf:.1f} s')
