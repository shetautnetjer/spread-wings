#!/usr/bin/env python3
"""Prints a graph without its row numbers, one sorted line per fact, so two
graphs of the same files can be compared whatever order their rows were
written in: the graph `update` leaves against the one `index` builds.

  graph_dump.py <graph.db>            every line
  graph_dump.py --hash <graph.db>     one hash per table, and one of all
  graph_dump.py --ord ...             with each file's place in the walk
  graph_dump.py --round N ...         weights to N decimals (to compare with
                                      a build that added them in another order)

A file is its path; a definition its file, start and name. Read-only.
"""
import hashlib
import sqlite3
import sys

args = sys.argv[1:]
want_hash = '--hash' in args
want_ord = '--ord' in args
digits = None
if '--round' in args:
    digits = int(args[args.index('--round') + 1])
    del args[args.index('--round'):args.index('--round') + 2]
paths = [a for a in args if not a.startswith('--')]
if len(paths) != 1:
    sys.exit(__doc__)

con = sqlite3.connect(f'file:{paths[0]}?mode=ro', uri=True)
con.execute("CREATE TEMP TABLE sym AS SELECT s.id, f.path || '@' || s.start || ':' || s.name AS k "
            "FROM symbols s JOIN files f ON f.id = s.file_id")
con.execute('CREATE INDEX temp.sym_id ON sym(id)')
SYM = "COALESCE((SELECT k FROM temp.sym WHERE id = {0}), CASE WHEN COALESCE({0}, 0) = 0 THEN '' ELSE '?gone?' END)"
PATH = "COALESCE((SELECT path FROM files WHERE id = {0}), CASE WHEN COALESCE({0}, 0) = 0 THEN '' ELSE '?gone?' END)"


def weight(col):
    return f'ROUND({col}, {digits})' if digits is not None else col


has_stamps = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE name = 'stamps'").fetchone()[0] == 1
ord_col = '(SELECT ord FROM stamps WHERE file_id = f.id)' if want_ord and has_stamps else "''"
tables = {
    'files': f'SELECT f.path, f.lang, f.dir, f.community, f.is_test, {ord_col} FROM files f',
    'symbols': 'SELECT f.path, s.name, s.kind, s.row, s.start, s.end_, s.end_row, s.sig, s.container, s.params '
               'FROM symbols s JOIN files f ON f.id = s.file_id',
    'imports': f"SELECT f.path, i.module, i.row, i.names, {PATH.format('i.dst')} "
               'FROM imports i JOIN files f ON f.id = i.file_id',
    'calls': f"SELECT f.path, c.row, c.start, c.callee, {SYM.format('c.in_symbol')}, c.text, c.note, c.qual "
             'FROM calls c JOIN files f ON f.id = c.file_id',
    'assigns': f"SELECT f.path, a.row, a.start, a.name, a.value, {SYM.format('a.in_symbol')} "
               'FROM assigns a JOIN files f ON f.id = a.file_id',
    'aliases': f"SELECT {PATH.format('a.file_id')}, a.alias, {PATH.format('a.dst')} FROM aliases a",
    'file_edges': f"SELECT {PATH.format('e.src')}, {PATH.format('e.dst')}, e.kind, {weight('e.weight')} FROM file_edges e",
    'call_edges': f"SELECT {PATH.format('e.file_id')}, e.row, {SYM.format('e.caller')}, {SYM.format('e.callee')}, "
                  f"{weight('e.weight')}, e.by_name, e.resolution FROM call_edges e",
    'communities': 'SELECT id, label, size, tests FROM communities',
}
total = hashlib.sha256()
for name, sql in tables.items():
    lines = sorted(name + '\t' + '\t'.join('' if v is None else repr(v) if isinstance(v, float) else str(v) for v in row)
                   for row in con.execute(sql))
    text = '\n'.join(lines) + '\n'
    total.update(text.encode())
    if want_hash:
        print(f'{name:12} {len(lines):8} {hashlib.sha256(text.encode()).hexdigest()[:16]}')
    else:
        sys.stdout.write(text)
if want_hash:
    print(f'{"all":12} {"":8} {total.hexdigest()[:16]}')
