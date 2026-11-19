#!/usr/bin/env python3
"""Takes every triple-quoted text out of src/*.goose, as it is, into
rust/src/sql.rs, so the Rust program runs the very scripts the Goose program
runs and none is retyped.

  scripts/sql-from-goose.py            write rust/src/sql.rs
  scripts/sql-from-goose.py --check    exit 1 if rust/src/sql.rs is not what
                                       the Goose sources give now

A text bound to a name (`let LINK_CALLS_SQL = \"\"\"...\"\"\";`) keeps the name.
Any other is named after its file and the line it starts on (GRAPH_L123).
"""
import glob, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_path = os.path.join(root, 'rust', 'src', 'sql.rs')
parts = ['// Made by scripts/sql-from-goose.py from src/*.goose. Not edited by hand.\n',
         '#![allow(dead_code)]\n']
for path in sorted(glob.glob(os.path.join(root, 'src', '*.goose'))):
    text = open(path, encoding='utf-8').read()
    stem = os.path.basename(path)[:-6].replace('-', '_').upper()
    at = 0
    while True:
        a = text.find('"""', at)
        if a < 0:
            break
        if '//' in text[text.rfind('\n', 0, a) + 1:a]:      # named in a comment, not a text
            at = a + 3
            continue
        b = text.find('"""', a + 3)
        assert b > 0, (path, 'unclosed text at offset', a)
        body = text[a + 3:b]
        line = text.count('\n', 0, a) + 1
        head = text[text.rfind('\n', 0, a) + 1:a]
        m = re.match(r'^let ([A-Z][A-Z0-9_]*) = $', head)
        name = m.group(1) if m else '%s_L%d' % (stem, line)
        hashes = '#'
        while ('"' + hashes) in body:
            hashes += '#'
        parts.append('\n// %s:%d\npub const %s: &str = r%s"%s"%s;\n' % (
            os.path.relpath(path, root), line, name, hashes, body, hashes))
        at = b + 3
made = ''.join(parts)
if '--check' in sys.argv:
    have = open(out_path, encoding='utf-8').read() if os.path.exists(out_path) else ''
    if have != made:
        sys.exit('rust/src/sql.rs is not what src/*.goose give now: run scripts/sql-from-goose.py')
    print('rust/src/sql.rs is in step with src/*.goose')
else:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    open(out_path, 'w', encoding='utf-8').write(made)
    print('wrote', os.path.relpath(out_path, root), 'with', made.count('pub const '), 'texts')
