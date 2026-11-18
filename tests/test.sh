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
check "mcp: tools/list names the five tools" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[1]); assert [t['name'] for t in d['result']['tools']] == ['overview','find','neighbors','callers','touches']"
check "mcp: find load returns web/store.ts" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[2]); r=json.loads(d['result']['content'][0]['text']); assert any(x['path']=='web/store.ts' for x in r)"
check "mcp: a missing argument is a tool error" "import json; d=json.loads(open('$work/mcp.txt').read().splitlines()[3]); assert d['result']['isError'] is True"

# Compiler answers: a tiny repo with two definitions each of ping and pong,
# called on an object (so matched by name), and a hand-made Swan map that
# resolves ping to x/b.py and pong to a library.
mkdir -p "$work/c/x"
# (Methods: a call on an object can only be a method, so module-level
# functions of the same name are no longer candidates for `obj.ping()`.)
printf 'class A:\n    def ping(self):\n        return 1\n\n    def pong(self):\n        return 1\n\n    def pang(self):\n        return 1\n\n    def peng(self):\n        return 1\n' > "$work/c/x/a.py"
printf 'class B:\n    def ping(self):\n        return 2\n\n    def pong(self):\n        return 2\n\n    def pang(self):\n        return 2\n\n    def peng(self):\n        return 2\n' > "$work/c/x/b.py"
printf 'def run(obj, other):\n    obj.ping()\n    obj.pong()\n    obj.pang(); other.pang()\n    obj.peng(); other.peng()\n' > "$work/c/x/c.py"
"$SW" index "$work/c" "$work/c.db" >/dev/null
# A hand-made Swan map: ping -> x/b.py; pong -> a library; the two pang calls
# on one line -> two different definitions; one answer (a library) for the
# two peng calls on one line.
swan_map() {  # swan_map <out.db> <root> <scip_time in ns>
python3 - "$1" "$2" "$3" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.executescript("""
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT, rows INTEGER, edited_mtime INTEGER);
CREATE TABLE symbols (id INTEGER PRIMARY KEY, name TEXT, def_file TEXT, def_line INTEGER, in_repo INTEGER);
CREATE TABLE occurrences (symbol_id INTEGER, file TEXT, start_line INTEGER, is_def INTEGER, by_name INTEGER, is_import INTEGER);
INSERT INTO symbols VALUES (1, 'ping', 'x/b.py', 1, 1), (2, 'pong', NULL, NULL, 0),
    (3, 'pang', 'x/a.py', 7, 1), (4, 'pang', 'x/b.py', 7, 1), (5, 'peng', NULL, NULL, 0);
INSERT INTO occurrences VALUES (1, 'x/c.py', 1, 0, 0, 0), (2, 'x/c.py', 2, 0, 0, 0),
    (3, 'x/c.py', 3, 0, 0, 0), (4, 'x/c.py', 3, 0, 0, 0), (5, 'x/c.py', 4, 0, 0, 0);
""")
d.execute("INSERT INTO meta VALUES ('root', ?), ('scip_time', ?)", (sys.argv[2], sys.argv[3]))
d.commit()
PY
}
# Built "in the future", so no file counts as changed since.
swan_map "$work/swan.db" "$work/c" 9000000000000000000
res() { echo "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','callers','$1','$2'])); r=sorted({(s['resolution'], s['defined_in']) for s in d['sites']})"; }
check "compiler: before Swan's answers, ping is matched by name" "$(res "$work/c.db" ping); assert {x[0] for x in r} == {'by_name'}"
"$SW" compiler "$work/c.db" "$work/swan.db" >/dev/null
check "compiler: ping is tied to x/b.py, the definition the compiler names" "$(res "$work/c.db" ping); assert r == [('compiler', 'x/b.py')]"
check "compiler: pong, resolved outside the repo, keeps no guessed links" "$(res "$work/c.db" pong); assert r == [('unlinked', '')]"
check "compiler: two calls on a line with different answers stay matched by name" "$(res "$work/c.db" pang); assert r == [('by_name', 'x/a.py,x/b.py')]"
check "compiler: one answer does not speak for two calls on a line" "$(res "$work/c.db" peng); assert r == [('by_name', 'x/a.py,x/b.py')]"
check "compiler: a missing Swan map is an error" "import subprocess; r=subprocess.run(['$SW','compiler','$work/c.db','$work/none.db'],capture_output=True); assert r.returncode != 0"
# A map older than the files: nothing is taken from it, and the run says so.
"$SW" index "$work/c" "$work/old.db" >/dev/null
swan_map "$work/swan_old.db" "$work/c" 1
check "compiler: files changed since the map was built are skipped, with a note" "import subprocess; o=subprocess.check_output(['$SW','compiler','$work/old.db','$work/swan_old.db'],text=True); assert '0 tied to one definition, 0 outside' in o and 'changed since the Swan map was built' in o"
check "compiler: after a stale map, ping is still matched by name" "$(res "$work/old.db" ping); assert {x[0] for x in r} == {'by_name'}"
# A map of some other folder is refused.
mkdir -p "$work/elsewhere"
swan_map "$work/swan_other.db" "$work/elsewhere" 9000000000000000000
check "compiler: a Swan map of another folder is an error" "import subprocess; r=subprocess.run(['$SW','compiler','$work/old.db','$work/swan_other.db'],capture_output=True,text=True); assert r.returncode != 0 and 'map the same folder' in r.stderr"

# touches: what changing a definition reaches, in one answer.
"$SW" touches "$db" total_area > "$work/touches.json"
check "touches: total_area is defined in app/models.py, called from app/main.py and the test, one group" "$(J touches.json); assert [(f['path'], f['why'][0], f['is_test']) for f in d['files']] == [('app/models.py','defines it',False),('app/main.py','calls it',False),('tests/test_models.py','calls it',True)] and d['tests'] == ['tests/test_models.py'] and d['summary']['files'] == 3 and d['summary']['call_sites'] == 2 and d['summary']['matched_by_name_only'] == 0 and d['summary']['communities'] == 1"
check "touches: a path narrows the name; an unknown name is an error" "import subprocess,json; d=json.loads(subprocess.check_output(['$SW','touches','$db','total_area','app/models.py'])); assert d['summary']['definitions'] == 1; r=subprocess.run(['$SW','touches','$db','no_such_name'],capture_output=True,text=True); assert r.returncode == 1 and 'no definition named' in r.stderr"

# Review findings (2026-11-17), each one a case that was wrong before.
q() { sqlite3 "$1" "$2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }

# A name defined in more than 50 places still links inside its own file.
mkdir -p "$work/many"
for i in $(seq 1 51); do printf 'def helper():\n    return %s\n\n\ndef use():\n    return helper()\n' "$i" > "$work/many/m$i.py"; done
"$SW" index "$work/many" "$work/many.db" >/dev/null
eq "common name: 51 files each calling their own helper() give 51 same_file links" "$(q "$work/many.db" "select resolution || ' ' || count(*) from call_edges group by resolution")" "same_file 51"

# ES imports: a statement over several lines, and `./x.js` naming the file itself.
"$SW" index tests/fixtures/esm "$work/esm.db" >/dev/null
eq "esm: a multi-line import is read, at the row it starts on" "$(q "$work/esm.db" "select i.module, i.names, i.row, (select path from files where id = i.dst) from imports i join files f on f.id = i.file_id where f.path = 'index.ts'")" "./store|load,save|1|store.ts"
eq "esm: its calls resolve through the import" "$(q "$work/esm.db" "select group_concat(distinct e.resolution) from call_edges e join files f on f.id = e.file_id where f.path = 'index.ts'")" "imported_name"
eq "esm: './util.js' links to util.js" "$(q "$work/esm.db" "select (select path from files where id = i.dst) from imports i join files f on f.id = i.file_id where f.path = 'main.js'")" "util.js"

# A Python package kept below another folder (python/mypkg).
"$SW" index tests/fixtures/nested "$work/nested.db" >/dev/null
eq "nested package: import mypkg.core finds python/mypkg/core.py, not python/other/core.py" "$(q "$work/nested.db" "select distinct (select path from files where id = i.dst) from imports i where i.module = 'mypkg.core'")" "python/mypkg/core.py"
eq "nested package: its three calls are linked, none marked external" "$(q "$work/nested.db" "select group_concat(coalesce(c.note, (select e.resolution from call_edges e where e.file_id = c.file_id and e.row = c.row)), ' ') from (select * from calls order by row) c")" "imported_file module_alias imported_name"

# outside_object: every binding counts, a type must end where the name ends,
# a parameter hides a module-level variable, importlib under any name.
"$SW" index tests/fixtures/outside "$work/outside.db" >/dev/null
want=$(grep -o '# want [a-z_]*' tests/fixtures/outside/app.py | sed 's/# want //' | paste -sd' ')
got=$(q "$work/outside.db" "select group_concat(coalesce(c.note, (select group_concat(distinct e.resolution) from call_edges e where e.file_id = c.file_id and e.row = c.row), 'unlinked'), ' ') from (select * from calls where callee = 'render' order by row) c")
eq "outside_object: the 12 cases in tests/fixtures/outside/app.py" "$got" "$want"
mkdir -p "$work/sub"
printf 'def f(d, a, b, rows):\n    d[a, b] = 1\n    x, d[0] = rows\n    [m, n] = rows\n    (p, q) = rows\n' > "$work/sub/t.py"
"$SW" index "$work/sub" "$work/sub.db" >/dev/null
eq "bindings: a subscript target binds no name; tuple and list targets bind theirs" "$(q "$work/sub.db" "select group_concat(name, ' ') from (select name from assigns order by row, name)")" "x m n p q"

# Rules found with PyCharm as the judge on Graphify's repo (2026-11-17): one
# case each in tests/fixtures/rules/app.py, with what it should be.
"$SW" index tests/fixtures/rules "$work/rules.db" >/dev/null
want=$(grep -o '# want [a-z_]*' tests/fixtures/rules/app.py | sed 's/# want //' | paste -sd' ')
got=$(q "$work/rules.db" "select group_concat(coalesce(c.note, (select group_concat(distinct e.resolution) from call_edges e join symbols s on s.id = e.callee where e.file_id = c.file_id and e.row = c.row and (s.name = c.callee or e.resolution = 'imported_name')), 'unlinked'), ' ') from (select k.* from calls k join files f on f.id = k.file_id where f.path = 'app.py' and k.callee in ('render', '_global_add', 'add') order by k.row) c")
eq "rules: loop variables, returned types, local values, aliased imports, methods on local objects (10 cases)" "$got" "$want"
eq "rules: a function's parameter names are stored, across a multi-line header" "$(printf 'def f(\n    a: int,\n    *rest,\n    key=len,\n    **kw,\n) -> int:\n    return a\n' > "$work/p.py"; mkdir -p "$work/pp" && cp "$work/p.py" "$work/pp/" && "$SW" index "$work/pp" "$work/pp.db" >/dev/null && q "$work/pp.db" "select params from symbols where name = 'f'")" ",a,rest,key,kw,"

# decide: answers that can't be written are not used.
mkdir -p "$work/dec/x"
printf 'class A:\n    def ping(self):\n        return 1\n' > "$work/dec/x/a.py"
printf 'class B:\n    def ping(self):\n        return 2\n' > "$work/dec/x/b.py"
printf 'def run(o, p):\n    o.ping()\n    o.ping(); p.ping()\n' > "$work/dec/x/c.py"
"$SW" index "$work/dec" "$work/dec.db" >/dev/null
fid=$(q "$work/dec.db" "select id from files where path = 'x/c.py'")
a=$(q "$work/dec.db" "select s.id from symbols s join files f on f.id = s.file_id where f.path = 'x/a.py' and s.name = 'ping'")
b=$(q "$work/dec.db" "select s.id from symbols s join files f on f.id = s.file_id where f.path = 'x/b.py' and s.name = 'ping'")
q "$work/dec.db" "insert into decisions (file_id, row, callee, choice, target, p) values ($fid, 2, 'ping', 'd99999', 99999, 950), ($fid, 3, 'ping', 'd$a', $a, 950), ($fid, 3, 'ping', 'd$b', $b, 950)"
out=$("$SW" decide-apply "$work/dec.db")
eq "decide: an answer naming no offered definition, and two answers that differ on one line, are not used" "$out" "spread-wings decide-apply: 0 answers applied, 3 not used"
eq "decide: those calls keep their by_name links" "$(q "$work/dec.db" "select resolution || ' ' || count(*) from call_edges group by resolution")" "by_name 6"
q "$work/dec.db" "insert into decisions (file_id, row, callee, choice, target, p) values ($fid, 2, 'ping', 'd$b', $b, 950)"
"$SW" decide-apply "$work/dec.db" >/dev/null
eq "decide: a valid answer becomes the only link" "$(q "$work/dec.db" "select e.resolution, (select path from files where id = s.file_id) from call_edges e join symbols s on s.id = e.callee where e.row = 2")" "decided|x/b.py"
check "decide: with nothing to ask, no key is needed" "import subprocess,os,time; e=dict(os.environ); e.pop('OPENROUTER_API_KEY',None); e['SPREAD_WINGS_CACHE']='$work/nocache'; t=time.time(); r=subprocess.run(['$SW','decide','$work/many.db'],capture_output=True,text=True,env=e); assert r.returncode == 0"
"$SW" index "$work/dec" "$work/dec2.db" >/dev/null
check "decide: with by_name calls and no key it stops at once, saying so" "import subprocess,os,time; e=dict(os.environ); e.pop('OPENROUTER_API_KEY',None); e['SPREAD_WINGS_CACHE']='$work/nocache'; t=time.time(); r=subprocess.run(['$SW','decide','$work/dec2.db'],capture_output=True,text=True,env=e); assert r.returncode != 0 and 'OPENROUTER_API_KEY is not set' in r.stderr and time.time() - t < 5, r.stderr"

# A graph written by another version is refused with what to do.
cp "$work/dec2.db" "$work/oldver.db"
q "$work/oldver.db" "delete from meta where key = 'schema'"
check "schema: a graph from another version says to rebuild it" "import subprocess; r=subprocess.run(['$SW','callers','$work/oldver.db','ping'],capture_output=True,text=True); assert r.returncode != 0 and 'rebuild it' in r.stderr, r.stderr"

# Goose, read by line (no tree-sitter grammar): definitions, imports, calls.
"$SW" index tests/fixtures/goose "$work/goose.db" >/dev/null
GQ() { echo "import sqlite3; c=sqlite3.connect('$work/goose.db')"; }
check "goose: functions (nested and extern too), a struct and a top-level let, with their lines" "$(GQ); got=c.execute(\"select f.path,s.name,s.kind,s.row,s.end_row from symbols s join files f on f.id=s.file_id order by 1,4\").fetchall(); assert got == [('main.goose','UNIT','variable',6,6),('main.goose','Box','struct',8,8),('main.goose','main','function',10,19),('shapes.goose','c_helper','function',3,3),('shapes.goose','area','function',5,5),('shapes.goose','total_area','function',7,12),('shapes.goose','twice','function',8,10)], got"
check "goose: comments, strings and raw strings hold no calls or definitions; methods and packages are not calls" "$(GQ); got=sorted(r[0] for r in c.execute(\"select callee from calls k join files f on f.id=k.file_id where f.path='main.goose'\")); assert got == ['print','str','total_area'], got"
check "goose: import .shapes links main.goose to shapes.goose, and total_area resolves through it" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','neighbors','$work/goose.db','main.goose'])); assert d['imports'] == ['shapes.goose'], d; s=json.loads(subprocess.check_output(['$SW','callers','$work/goose.db','total_area']))['sites']; assert [(x['path'],x['line'],x['in'],x['defined_in']) for x in s] == [('main.goose',16,'main','shapes.goose')] and s[0]['resolution'] != 'by_name', s"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
