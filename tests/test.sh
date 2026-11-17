#!/usr/bin/env bash
# Indexes tests/fixtures/mini (Python, TypeScript, Rust) and checks the
# graph, the CLI queries and the MCP server against known answers.
set -uo pipefail
cd "$(dirname "$0")/.."
SW=bin/spread-wings
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
db="$work/mini.db"
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
check() { if python3 -c "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

"$SW" index tests/fixtures/mini "$db" >/dev/null || { echo "FAIL index"; exit 1; }
"$SW" overview "$db" > "$work/overview.json"
"$SW" find "$db" total_area > "$work/find.json"
"$SW" callers "$db" total_area > "$work/callers.json"
"$SW" neighbors "$db" app/main.py > "$work/main.json"
"$SW" neighbors "$db" web/index.ts > "$work/index.json"
"$SW" neighbors "$db" core/src/lib.rs > "$work/lib.json"

J() { echo "import json; d=json.load(open('$work/$1'))"; }
check "overview: 8 files across Python, TypeScript and Rust" "$(J overview.json); assert d['files'] == 8"
check "tests: a test file joins the community of the code it imports" "$(J overview.json); c=[c for c in d['communities'] if c['test_files'] > 0]; assert len(c) == 1 and c[0]['code_files'] >= 1 and any(f.startswith('app/') for f in c[0]['main_files'])"
check "overview: every community has a label and size" "$(J overview.json); assert all(c['label'] and c['code_files'] + c['test_files'] > 0 for c in d['communities'])"
check "overview: says links are matched by name or path" "$(J overview.json); assert 'not compiler-resolved' in d['evidence']"
check "find: total_area is a function in app/models.py at line 6" "$(J find.json); r=d[0]; assert (r['name'], r['kind'], r['path'], r['line']) == ('total_area', 'function', 'app/models.py', 6)"
check "find: Python return-annotated defs are found (area)" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','find','$db','area'])); assert any(r['name']=='area' and r['path']=='app/models.py' for r in d)"
check "callers: total_area is called from run() in app/main.py:7 and from the test" "$(J callers.json); assert [(s['path'], s['line'], s['in']) for s in d['sites']] == [('app/main.py', 7, 'run'), ('tests/test_models.py', 5, 'test_total_area')]"
check "python: main.py imports app/models.py, and app/util.py through 'from . import util'" "$(J main.json); assert d['imports'] == ['app/models.py', 'app/util.py']"
check "python: main.py calls into models.py and util.py (by name)" "$(J main.json); assert {'app/models.py', 'app/util.py'} <= set(d['calls_into'])"
check "typescript: index.ts imports ./store" "$(J index.json); assert d['imports'] == ['web/store.ts']"
check "rust: lib.rs's 'mod state;' links to state.rs" "$(J lib.json); assert 'core/src/state.rs' in d['imports']"
check "rust: pub fn and pub struct are definitions" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','find','$db','Counter'])); assert any(r['kind']=='struct' and r['path']=='core/src/state.rs' for r in d)"
check "unknown file: neighbors fails with a message" "import subprocess; r=subprocess.run(['$SW','neighbors','$db','nope.py'],capture_output=True,text=True); assert r.returncode == 1 and 'no such file' in r.stderr"

check "callers: each site says how it was resolved (imported_name for total_area)" "$(J callers.json); assert all(s['resolution'] == 'imported_name' and s['defined_in'] == 'app/models.py' for s in d['sites'])"
check "typescript: load() in index.ts resolves to store.ts through its import" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$db','load'])); s=[x for x in d['sites'] if x['path']=='web/index.ts']; assert s and s[0]['resolution']=='imported_name' and s[0]['defined_in']=='web/store.ts'"
check "rust: new_counter() resolves through the module import" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$db','new_counter'])); assert d['sites'][0]['defined_in']=='core/src/state.rs'"
check "resolution: --resolution is accepted and recorded" "import subprocess; subprocess.check_call(['$SW','index','tests/fixtures/mini','$work/r2.db','--resolution','2'],stdout=subprocess.DEVNULL)"

# Same repo, same graph: indexing is deterministic.
"$SW" index tests/fixtures/mini "$work/again.db" >/dev/null
"$SW" overview "$work/again.db" > "$work/again.json"
check "deterministic: a second index gives the same overview" "import json; a=json.load(open('$work/overview.json')); b=json.load(open('$work/again.json')); a.pop('root'); b.pop('root'); assert a == b"

# MCP: one JSON message per line; tools/list and a call.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find","arguments":{"name":"load"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"find","arguments":{}}}' \
  | "$SW" serve "$db" > "$work/mcp.txt"
check "mcp: four replies, each one valid JSON line (none for the notification)" "import json; ls=open('$work/mcp.txt').read().splitlines(); assert len(ls) == 4 and all(json.loads(l) for l in ls)"
check "mcp: tools/list names the four tools" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[1]); assert [t['name'] for t in d['result']['tools']] == ['overview','find','neighbors','callers']"
check "mcp: find load returns web/store.ts" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[2]); r=json.loads(d['result']['content'][0]['text']); assert any(x['path']=='web/store.ts' for x in r)"
check "mcp: a missing argument is a tool error" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[3]); assert d['result']['isError'] is True"

# Compiler answers: a tiny repo with two definitions each of ping and pong,
# called on an object (so matched by name), and a hand-made Swan map that
# resolves ping to x/b.py and pong to a library.
mkdir -p "$work/c/x"
printf 'def ping():\n    return 1\n\n\ndef pong():\n    return 1\n' > "$work/c/x/a.py"
printf 'def ping():\n    return 2\n\n\ndef pong():\n    return 2\n' > "$work/c/x/b.py"
printf 'def run(obj):\n    obj.ping()\n    obj.pong()\n' > "$work/c/x/c.py"
"$SW" index "$work/c" "$work/c.db" >/dev/null
python3 - "$work/swan.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.executescript("""
CREATE TABLE symbols (id INTEGER PRIMARY KEY, name TEXT, def_file TEXT, def_line INTEGER, in_repo INTEGER);
CREATE TABLE occurrences (symbol_id INTEGER, file TEXT, start_line INTEGER, is_def INTEGER, by_name INTEGER, is_import INTEGER);
INSERT INTO symbols VALUES (1, 'ping', 'x/b.py', 0, 1), (2, 'pong', NULL, NULL, 0);
INSERT INTO occurrences VALUES (1, 'x/c.py', 1, 0, 0, 0), (2, 'x/c.py', 2, 0, 0, 0);
""")
d.commit()
PY
check "compiler: before Swan's answers, ping is matched by name" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$work/c.db','ping'])); assert {s['resolution'] for s in d['sites']} == {'by_name'}"
"$SW" compiler "$work/c.db" "$work/swan.db" >/dev/null
check "compiler: ping is tied to x/b.py, the definition the compiler names" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$work/c.db','ping'])); assert [(s['resolution'], s['defined_in']) for s in d['sites']] == [('compiler', 'x/b.py')]"
check "compiler: pong, resolved outside the repo, keeps no guessed links" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$work/c.db','pong'])); assert [(s['resolution'], s['defined_in']) for s in d['sites']] == [('unlinked', '')]"
check "compiler: a missing Swan map is an error" "import subprocess; r=subprocess.run(['$SW','compiler','$work/c.db','$work/none.db'],capture_output=True); assert r.returncode != 0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
