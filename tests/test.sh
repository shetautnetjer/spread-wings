#!/usr/bin/env bash
# Indexes tests/fixtures/mini (Python, TypeScript, Rust) and checks the
# graph, the CLI queries and the MCP server against known answers.
set -uo pipefail
cd "$(dirname "$0")/.."
# SPREAD_WINGS names another build to put through the same checks.
SW=${SPREAD_WINGS:-bin/spread-wings}
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

# Definitions read from the syntax tree by node kind (2026-11-18): TypeScript,
# TSX, JavaScript and Rust. tests/fixtures/kinds spells each definition in a
# way the earlier list of shapes missed (0.1.0 found 18 of these 57), and
# holds one call for each linking rule added with it.
"$SW" index tests/fixtures/kinds "$work/kinds.db" >/dev/null
defs() { q "$work/kinds.db" "select group_concat(x, ' ') from (select s.name || ':' || s.kind || ':' || s.row || coalesce(':' || s.container, '') as x from symbols s join files f on f.id = s.file_id where f.path = '$1' order by s.start)"; }
eq "kinds: TypeScript: typed and generic arrow constants, a generator, a declared function, constants holding a call, an interface's and a class's methods, function-typed properties, enum, type" "$(defs web/shapes.ts)" \
   "parse:function:2 load:function:5 steps:function:9 pick:function:13 ambient:function:19 useStore:function:21 run:function:23 Port:interface:26 close:function:27:Port onData:function:28:Port Session:class:32 onData:function:34:Session constructor:function:35:Session close:function:36:Session push:function:40:Session open:function:41:Session create:function:42:Session Color:enum:47 Handler:type:48 handle:function:48:Handler push:function:50 main:function:52"
eq "kinds: the overloads of one function are one definition, from the first signature to the end of the body" "$(q "$work/kinds.db" "select row, end_row, sig from symbols where name = 'pick'")" "13|17|function pick(a: string): string;"
eq "kinds: a constant holding a call's result that nothing calls, and a property that is no function, are not definitions" "$(q "$work/kinds.db" "select count(*) from symbols where name in ('unused', 'label')")" "0"
eq "kinds: parameters: a constructor's 'private readonly id', past Rust's 'pub(crate)', and not a call's arguments" "$(q "$work/kinds.db" "select group_concat(name || coalesce(params, ''), ' ') from (select * from symbols where name in ('constructor', 'total', 'run') order by name)")" "constructor,id,name, run total,items,extra,"
eq "kinds: Rust: pub(crate), tuple and unit structs, a union, generics and where clauses, an unsafe trait and its methods, const fn, extern fn, a type alias" "$(defs core/src/lib.rs)" \
   "Pair:struct:4 Unit:struct:5 Bits:struct:6 Mode:enum:7 Sink:trait:8 put:function:9:Sink flush:function:10:Sink Shared:type:12 Pair:impl:14 put:function:15:Pair Pair:impl:18 new:function:19:Pair len:function:20:Pair twice:function:21:Pair inner:function:22:Pair total:function:25 helper:function:26 new_count:function:33 only_in_rust:function:35 len:function:37 flush:function:38 drive:function:40"
eq "kinds: JavaScript: a class's methods, a private #method, a function expression and an arrow function held by const and var" "$(defs web/legacy.js)" "Cache:class:1 get:function:2:Cache make:function:3:Cache wrap:function:6 twice:function:7 boot:function:9 Vault:class:14 #seal:function:15:Vault unlock:function:16:Vault"
eq "kinds: Rust 'pub(crate) mod store;' links lib.rs to store.rs" "$(q "$work/kinds.db" "select (select path from files where id = i.dst) from imports i where i.module = 'mod::store'")" "core/src/store.rs"
# What a call is linked to, as rule>name@line[/container] for each link.
linked() { q "$work/kinds.db" "select coalesce((select group_concat(e.resolution || '>' || s.name || '@' || s.row || coalesce('/' || s.container, ''), ' ') from call_edges e join symbols s on s.id = e.callee where e.file_id = c.file_id and e.row = c.row and s.name = c.callee), 'unlinked') from calls c join files f on f.id = c.file_id where f.path = '$1' and c.row = $2 and c.callee = '$3'"; }
eq "links: a bare call reaches the plain function, not the method of that name (TypeScript)" "$(linked web/shapes.ts 55 push)" "same_file>push@50"
eq "links: the same in Rust, for len() beside impl Pair's len" "$(linked core/src/lib.rs 43 len)" "same_file>len@37"
eq "links: no call on an object is tied to a plain function, but through the module it is imported from" "$(q "$work/kinds.db" "select count(*) from call_edges e join symbols s on s.id = e.callee join calls c on c.file_id = e.file_id and c.row = e.row and c.callee = s.name where instr(c.text, '.') > 0 and coalesce(s.container, '') = '' and e.resolution <> 'module_alias'")" "0"
eq "links: items.push() is tied to the method push only; list.steps() to nothing; steps() to the function, through the imported file" "$(linked web/shapes.ts 54 push), $(linked web/use.ts 8 steps), $(linked web/use.ts 9 steps)" "same_file>push@40/Session, unlinked, imported_file>steps@9"
eq "links: shapes.pick() after 'import * as shapes' reaches the function" "$(linked web/use.ts 7 pick)" "module_alias>pick@13"
eq "links: a method of an imported file is reached through an object (s.open())" "$(linked web/use.ts 6 open)" "imported_file>open@41/Session"
eq "links: a TypeScript call is not tied to a Rust function of that name" "$(linked web/shapes.ts 58 only_in_rust)" "unlinked"
eq "links: a call inside a method belongs to the method" "$(q "$work/kinds.db" "select s.name || '/' || s.container from calls c join symbols s on s.id = c.in_symbol where c.callee = 'run'")" "close/Session"
eq "links: this.push() is the push of the calling method's own class" "$(linked web/shapes.ts 38 push)" "own_type>push@40/Session"
eq "links: this.#seal() calls the private method #seal" "$(linked web/legacy.js 16 '#seal')" "own_type>#seal@15/Vault"
eq "links: Session.create() and Cache.make() are the methods of the type named" "$(linked web/shapes.ts 57 create) $(linked web/legacy.js 11 make)" "type_name>create@42/Session type_name>make@3/Cache"
eq "links: Vec::new() beside impl Pair's new is not Pair's; Pair::new() is" "$(linked core/src/lib.rs 27 new) $(linked core/src/lib.rs 28 new)" "unlinked type_name>new@19/Pair"
eq "links: self.len() in impl Pair is Pair's len; LOGGER.put() is a call on a value, not on a type" "$(linked core/src/lib.rs 21 len) $(q "$work/kinds.db" "select qual from calls where callee = 'put' and text like 'LOGGER%'")" "own_type>len@20/Pair LOGGER"
eq "links: the name before the call: this, a type under generic arguments, a field, none after a call" "$(q "$work/kinds.db" "select group_concat(text || '=' || coalesce(nullif(qual, ''), '-'), ' ') from (select distinct text, qual from calls where text in ('this.push', 'Pair::<u8>::new', 'self.0.len', 'text.split(\",\").map', 'push') order by text)")" "Pair::<u8>::new=Pair push=- self.0.len=0 text.split(\",\").map=- this.push=this"
eq "links: a function nested in a function is no method, and its bare call reaches it" "$(q "$work/kinds.db" "select coalesce(container, 'none') from symbols where name = 'helper'") $(linked core/src/lib.rs 30 helper)" "none same_file>helper@26"

# score: the graph beside a Swan map of the same code. A hand-made map says
# where seven of the fixture's calls resolve (lines from 0), one of them
# outside the repo and one to another file than the graph linked, and has
# one definition the graph lacks.
python3 - "$work/swan_kinds.db" "$(cd tests/fixtures/kinds && pwd -P)" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.executescript("""
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT, rows INTEGER, edited_mtime INTEGER);
CREATE TABLE symbols (id INTEGER PRIMARY KEY, name TEXT, kind TEXT, language TEXT, def_file TEXT, def_line INTEGER, in_repo INTEGER);
CREATE TABLE occurrences (symbol_id INTEGER, file TEXT, start_line INTEGER, is_def INTEGER, by_name INTEGER, is_import INTEGER);
INSERT INTO symbols VALUES
    (1, 'parse', 'variable', 'typescript', 'web/shapes.ts', 1, 1),
    (2, 'close', 'method', 'typescript', 'web/shapes.ts', 35, 1),
    (3, 'close', 'method', 'typescript', 'web/shapes.ts', 26, 1),
    (4, 'push', 'method', 'typescript', 'web/shapes.ts', 39, 1),
    (5, 'push', 'method', 'typescript', NULL, NULL, 0),
    (6, 'open', 'method', 'typescript', 'web/shapes.ts', 40, 1),
    (7, 'missing', 'function', 'typescript', 'web/shapes.ts', 99, 1),
    (8, 'flush', 'method', 'rust', 'core/src/store.rs', 3, 1),
    (9, 'len', 'function', 'rust', 'core/src/lib.rs', 36, 1),
    (10, '<constructor>', 'constructor', 'typescript', 'web/shapes.ts', 34, 1),
    (11, '#seal', 'method', 'typescript', 'web/legacy.js', 14, 1);
INSERT INTO occurrences VALUES
    (3, 'web/shapes.ts', 52, 0, 0, 0), (5, 'web/shapes.ts', 53, 0, 0, 0), (4, 'web/shapes.ts', 37, 0, 0, 0),
    (6, 'web/use.ts', 5, 0, 0, 0), (1, 'web/use.ts', 4, 0, 0, 0),
    (8, 'core/src/lib.rs', 40, 0, 0, 0), (9, 'core/src/lib.rs', 42, 0, 0, 0);
""")
d.execute("INSERT INTO meta VALUES ('root', ?), ('scip_time', '9000000000000000000')", (sys.argv[2],))
d.commit()
PY
"$SW" score "$work/kinds.db" "$work/swan_kinds.db" > "$work/score.json" 2>"$work/score.err"
SC() { echo "import json; d=json.load(open('$work/score.json')); L={(r['language'], r['rule']): (r['links'], r['judged'], r['right'], r['other_file'], r['outside']) for r in d['links']}; D={(r['language'], r['kind']): (r['in_swan'], r['in_graph']) for r in d['definitions']}; C={(r['language'], r['kind']): (r['in_swan'], r['in_graph']) for r in d['called']}"; }
check "score: links per language and rule: how many, how many Swan judges, right, in another file, outside the repo" "$(SC); assert L[('typescript', 'same_file')] == (6, 3, 2, 0, 1), L; assert L[('rust', 'same_file')] == (10, 2, 1, 1, 0), L; assert L[('typescript', 'own_type')] == (2, 1, 1, 0, 0) and L[('typescript', 'imported_name')] == (1, 1, 1, 0, 0) and L[('typescript', 'imported_file')] == (2, 1, 1, 0, 0) and L[('typescript', 'module_alias')] == (1, 0, 0, 0, 0) and L[('javascript', 'type_name')] == (1, 0, 0, 0, 0), L"
check "score: a call linked to two candidates is one call judged, with the right link among them" "import json; d=json.load(open('$work/score.json')); r=[x for x in d['links'] if (x['language'], x['rule']) == ('typescript', 'same_file')][0]; assert (r['calls_judged'], r['calls_with_the_right_link']) == (2, 1), r"
check "score: definitions Swan has and the graph has at the same place, per language and kind (Swan's <constructor> is the graph's constructor)" "$(SC); assert D == {('typescript', 'method'): (5, 5), ('typescript', 'constructor'): (1, 1), ('typescript', 'function'): (1, 0), ('rust', 'method'): (1, 1), ('rust', 'function'): (1, 1)}, D"
check "score: the same for the definitions the repo's calls reach, a constant holding a function among them" "$(SC); assert C == {('typescript', 'method'): (3, 3), ('typescript', 'variable'): (1, 1), ('rust', 'method'): (1, 1), ('rust', 'function'): (1, 1)}, C"
check "score: nothing is written to the graph" "import subprocess; a=subprocess.check_output(['sqlite3','$work/kinds.db','select count(*), group_concat(distinct resolution) from call_edges; select count(*) from symbols'],text=True); subprocess.check_call(['$SW','score','$work/kinds.db','$work/swan_kinds.db'],stdout=subprocess.DEVNULL); b=subprocess.check_output(['sqlite3','$work/kinds.db','select count(*), group_concat(distinct resolution) from call_edges; select count(*) from symbols'],text=True); assert a == b"
check "score: a Swan map whose symbols carry no kind is refused, saying to rebuild it" "import subprocess; r=subprocess.run(['$SW','score','$work/c.db','$work/swan.db'],capture_output=True,text=True); assert r.returncode != 0 and 'no kind and language' in r.stderr, r.stderr"
check "score: a Swan map of another folder is an error" "import subprocess; r=subprocess.run(['$SW','score','$work/kinds.db','$work/swan_other.db'],capture_output=True,text=True); assert r.returncode != 0 and 'map the same folder' in r.stderr, r.stderr"

# compiler, on every call site (2026-11-18): Swan's answer replaces a link
# any rule made, adds the link no rule could, and removes a link to a
# namesake when the call is of a value. The fixture's map plus two answers:
# list.steps() is the function steps, and helper() in lib.rs is a value
# defined in store.rs.
cp "$work/kinds.db" "$work/kindsc.db"
cp "$work/swan_kinds.db" "$work/swan_fix.db"
python3 - "$work/swan_fix.db" <<'PY'
import sqlite3, sys
d = sqlite3.connect(sys.argv[1])
d.executescript("""
INSERT INTO symbols VALUES (12, 'steps', 'function', 'typescript', 'web/shapes.ts', 8, 1),
    (13, 'helper', 'variable', 'rust', 'core/src/store.rs', 0, 1);
INSERT INTO occurrences VALUES (12, 'web/use.ts', 7, 0, 0, 0), (13, 'core/src/lib.rs', 29, 0, 0, 0);
""")
d.commit()
PY
linkedc() { q "$work/kindsc.db" "select coalesce((select group_concat(e.resolution || '>' || s.name || '@' || s.row || coalesce('/' || s.container, ''), ' ') from call_edges e join symbols s on s.id = e.callee where e.file_id = c.file_id and e.row = c.row and s.name = c.callee), coalesce(c.note, 'unlinked')) from calls c join files f on f.id = c.file_id where f.path = '$1' and c.row = $2 and c.callee = '$3'"; }
"$SW" compiler "$work/kindsc.db" "$work/swan_fix.db" > "$work/said.txt"
eq "compiler: a link the same-file rule made to the wrong type's method is corrected (s.flush() is Store's, in store.rs)" "$(linked core/src/lib.rs 41 flush) -> $(linkedc core/src/lib.rs 41 flush)" "same_file>flush@10/Sink -> compiler>flush@4/Store"
eq "compiler: a call shared between two candidates keeps the one the compiler names" "$(linked web/shapes.ts 53 close) -> $(linkedc web/shapes.ts 53 close)" "same_file>close@27/Port same_file>close@36/Session -> compiler>close@27/Port"
eq "compiler: a call no rule could tie gets the compiler's link" "$(linked web/use.ts 8 steps) -> $(linkedc web/use.ts 8 steps)" "unlinked -> compiler>steps@9"
eq "compiler: a call the compiler resolves outside the repo keeps no guessed link" "$(linked web/shapes.ts 54 push) -> $(linkedc web/shapes.ts 54 push)" "same_file>push@40/Session -> compiler_outside"
eq "compiler: a call of a value defined in another file loses its link to the namesake function" "$(linked core/src/lib.rs 30 helper) -> $(linkedc core/src/lib.rs 30 helper)" "same_file>helper@26 -> compiler_value"
eq "compiler: a site the map says nothing about is left as the rules had it" "$(linkedc web/use.ts 9 steps) $(linkedc web/shapes.ts 57 create)" "imported_file>steps@9 type_name>create@42/Session"
check "compiler: it says what it did: tied (as they were, narrowed, corrected, new), outside, values" "s=open('$work/said.txt').read(); assert 'covers 9: 7 tied to one definition, 1 outside the repo, 1 calls of a value the graph does not hold, 0 left (unclear)' in s, s; assert 'Of those tied: 4 as they were, 1 narrowed from several, 1 corrected, 1 new. Guessed links removed at 1 outside sites and 1 value sites' in s, s"
"$SW" score "$work/kindsc.db" "$work/swan_fix.db" > "$work/scorec.json"
check "compiler: afterwards every link the map can judge is right" "import json; d=json.load(open('$work/scorec.json')); j=sum(r['judged'] for r in d['links']); assert j == 7 and j == sum(r['right'] for r in d['links']), d['links']"

# survey: the projects a repo holds, read from manifest, lock and version
# files (tests/fixtures/survey: a pnpm workspace with a bun package and one
# outside the workspace, two Python projects, a cargo workspace with an
# excluded crate and a fuzz crate, a Go module, a Maven project, and a
# package.json under dist/ that is build output).
cp -r tests/fixtures/survey "$work/survey"
before=$(cd "$work/survey" && find . | sort | sha256sum)
"$SW" survey "$work/survey" > "$work/survey.json"
SV() { echo "import json; d=json.load(open('$work/survey.json')); P={(p['path'], p['kind']): p for p in d['projects']}; W=lambda p: {k: (v['version'], v['from']) for k, v in p['wants'].items()}"; }
check "survey: twelve projects of five kinds, in path order, nothing from dist/" "$(SV); assert d['count'] == {'node': 4, 'python': 2, 'rust': 4, 'go': 1, 'java': 1, 'deno': 0}, d['count']; assert [p['path'] for p in d['projects']] == ['.', 'core', 'core/crates/engine', 'core/crates/skip', 'core/fuzz', 'extras/old', 'go/svc', 'java/app', 'packages/tools', 'packages/web', 'services/api', 'services/legacy']"
check "survey: the root is a pnpm workspace; .nvmrc beside mise.toml wins for Node; the version drops its checksum" "$(SV); p=P[('.', 'node')]; assert p['package_manager'] == {'name': 'pnpm', 'from': 'package.json packageManager'}, p; assert W(p) == {'node': ('22.3.0', '.nvmrc'), 'pnpm': ('9.1.0', 'package.json packageManager')}, W(p); assert p['workspace'] == {'root': '.', 'from': 'package.json workspaces', 'is_root': True}, p"
check "survey: a member package takes the workspace's manager and Node, and keeps its own engines range beside the pinned version" "$(SV); p=P[('packages/web', 'node')]; assert p['name'] == '@fixture/web' and p['package_manager']['name'] == 'pnpm'; assert W(p)['node'] == ('22.3.0', '.nvmrc') and W(p)['node.requires'] == ('>=22', 'packages/web/package.json engines'), W(p); assert p['workspace']['member'] is True and p['workspace']['root'] == '.'; assert (p['test_script'], p['typescript'], p['tsconfigs']) == ('vitest run', '^5.4.0', ['tsconfig.app.json', 'tsconfig.json']), p"
check "survey: a package with its own lock file uses that manager (bun), and its .bun-version" "$(SV); p=P[('packages/tools', 'node')]; assert p['package_manager'] == {'name': 'bun', 'from': 'packages/tools/bun.lock'}, p; assert W(p)['bun'] == ('1.2.3', 'packages/tools/.bun-version')"
check "survey: a package the workspace does not list is not a member; volta pins its Node" "$(SV); p=P[('extras/old', 'node')]; assert p['workspace']['member'] is False and W(p)['node'] == ('18.20.0', 'extras/old/package.json volta'), p"
check "survey: node_modules is not there, and is said to be" "$(SV); assert all(p['dependencies_installed'] == {'installed': False} for p in d['projects'] if p['kind'] == 'node')"
check "survey: a uv project: its pinned Python beside requires-python, its virtualenv and that one's Python, pytest" "$(SV); p=P[('services/api', 'python')]; assert (p['name'], p['manifest'], p['package_manager']['name']) == ('api', 'pyproject.toml', 'uv'), p; assert W(p) == {'python': ('3.12.4', 'services/api/.python-version'), 'python.requires': ('>=3.11', 'services/api/pyproject.toml requires-python')}, W(p); assert p['environment'] == {'venv': 'services/api/.venv', 'python': '3.12.4'} and p['tests'] == 'pytest', p"
check "survey: a setup.py project: pip from requirements.txt, Python from the mise.toml at the top, no virtualenv" "$(SV); p=P[('services/legacy', 'python')]; assert (p['manifest'], p['package_manager']['name'], p['environment']) == ('setup.py', 'pip', None), p; assert W(p) == {'python': ('3.12', 'mise.toml')}, W(p)"
check "survey: a cargo workspace: its member, the crate it excludes, and a fuzz crate that is a workspace of its own; the pinned toolchain reaches all of them" "$(SV); e=P[('core/crates/engine', 'rust')]; assert P[('core', 'rust')]['workspace']['is_root'] is True; assert e['name'] == 'engine' and e['workspace'] == {'root': 'core', 'from': 'core/Cargo.toml workspace', 'is_root': False, 'member': True}, e; assert W(e) == {'rust': ('1.88.0', 'core/rust-toolchain.toml'), 'rust.requires': ('>=1.75', 'core/crates/engine/Cargo.toml rust-version')}, W(e); assert P[('core/crates/skip', 'rust')]['workspace']['member'] is False; assert P[('core/fuzz', 'rust')]['workspace'] == {'root': 'core/fuzz', 'from': 'core/fuzz/Cargo.toml workspace', 'is_root': True}"
check "survey: a Go module below the top: its module path, Go version and toolchain; a Maven project" "$(SV); g=P[('go/svc', 'go')]; assert g['name'] == 'example.com/svc' and W(g) == {'go': ('1.22', 'go/svc/go.mod'), 'go.toolchain': ('1.22.3', 'go/svc/go.mod toolchain')}, g; assert P[('java/app', 'java')]['build_tool'] == 'maven'"
eq "survey: it only reads: the repo is as it was" "$(cd "$work/survey" && find . | sort | sha256sum)" "$before"
mkdir "$work/survey/node_modules"
"$SW" survey "$work/survey" > "$work/survey.json"
check "survey: with node_modules at the workspace root, its packages' dependencies are installed there" "$(SV); assert P[('packages/web', 'node')]['dependencies_installed'] == {'installed': True, 'at': 'node_modules'}, P[('packages/web', 'node')]"
check "survey: says nothing was run, and a path that is no folder is an error" "$(SV); import subprocess; assert 'nothing of the repo was run' in d['evidence']; r=subprocess.run(['$SW','survey','$work/survey/package.json'],capture_output=True,text=True); assert r.returncode != 0"

# update (2026-11-18): the graph it leaves is the one index builds from the
# same files. A repo made of the fixtures (mini at the top; kinds, rules,
# esm, goose, nested and outside below more/; and more/ext, where a module
# is imported that the repo does not hold), then one change at a time.
# After each, tests/graph_dump.py (a graph without its row numbers) must
# print the same for the updated graph and for a fresh one.
up="$work/up"; ug="$work/up.db"
mkdir -p "$up/more/ext"; cp -r tests/fixtures/mini/. "$up/"
for x in kinds rules esm goose nested outside; do cp -r "tests/fixtures/$x" "$up/more/$x"; done
printf 'import gadgets\n\n\ndef go():\n    return gadgets.build(1)\n' > "$up/more/ext/use.py"
printf 'def build(x):\n    return x\n' > "$up/more/ext/make.py"
sleep 4   # a file written in the last three seconds is read again whatever its times say: let them settle
"$SW" index "$up" "$ug" >/dev/null
dump() { python3 tests/graph_dump.py --ord "$1"; }
as_index_of() { "$SW" index "$1" "$work/ref.db" >/dev/null && { [ "$(dump "$2")" = "$(dump "$work/ref.db")" ] && echo same || echo different; }; }
as_index() { as_index_of "$up" "$ug"; }
U() { "$SW" update "$up" "$ug" > "$work/u.json" 2>"$work/u.err"; echo "import json; d=json.load(open('$work/u.json'))"; }
top_line() { printf '%s\n' "$2" | cat - "$up/$1" > "$work/t" && cp "$work/t" "$up/$1"; }

check "update: nothing changed: no file is read, no call is tied again" "$(U); assert d['built_whole'] is False and d['files'] > 20 and d['looked_at'] == 0 and d['changed'] == [] and d['calls_tied_again'] == 0, d"
eq "update: ... and the graph is as index left it" "$(as_index)" same

top_line app/models.py '# a note'
eq "graph_dump: a graph from before a change is not the one index builds after it" "$(as_index)" different
check "update: a line added above a file's functions: the file is read again, and only its own calls are tied again" "$(U); assert d['changed'] == ['app/models.py'] and d['added'] == [] and d['removed'] == [] and d['files_with_calls_tied_again'] == ['app/models.py'] and 0 < d['calls_tied_again'] < d['calls'], d"
eq "update: ... the call into it from another file keeps its link, now to the function's new row" "$(q "$ug" "select group_concat(e.resolution || '>' || s.name || '@' || s.row, ' ') from call_edges e join symbols s on s.id = e.callee join files f on f.id = e.file_id where f.path = 'app/main.py' and s.name = 'total_area'")" "imported_name>total_area@7"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

top_line app/main.py '# a note'
check "update: a file with imports read again: only that file" "$(U); assert d['changed'] == ['app/main.py'] and d['files_with_calls_tied_again'] == ['app/main.py'], d"
eq "update: ... each of its two imports is tied once" "$(q "$ug" "select count(*) from file_edges e join files f on f.id = e.src where f.path = 'app/main.py' and e.kind = 'import'")" 2
eq "update: ... and the graph is the one index builds" "$(as_index)" same

sed -i 's/def total_area/def total_size/' "$up/app/models.py"
check "update: a function renamed: the calls of its old name in other files are tied again" "$(U); assert d['changed'] == ['app/models.py'] and {'app/main.py', 'tests/test_models.py'} <= set(d['files_with_calls_tied_again']), d"
eq "update: ... and have no link left" "$(q "$ug" "select count(*) from call_edges e join calls c on c.file_id = e.file_id and c.row = e.row join files f on f.id = e.file_id where f.path = 'app/main.py' and c.callee = 'total_area'")" 0
eq "update: ... and the graph is the one index builds" "$(as_index)" same

printf 'def total_area(shapes):\n    return 0\n' > "$up/app/areas.py"
check "update: a file added: listed, and the calls of a name it defines are tied again" "$(U); assert d['added'] == ['app/areas.py'] and d['changed'] == [] and 'app/main.py' in d['files_with_calls_tied_again'], d"
eq "update: ... to it" "$(q "$ug" "select group_concat(e.resolution || '>' || g.path, ' ') from call_edges e join symbols s on s.id = e.callee join files g on g.id = s.file_id join files f on f.id = e.file_id where f.path = 'app/main.py' and s.name = 'total_area'")" "by_name>app/areas.py"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

mv "$up/web/store.ts" "$up/web/stores.ts"
check "update: a file renamed is one removed and one added, and the file that imported it is tied again" "$(U); assert d['removed'] == ['web/store.ts'] and d['added'] == ['web/stores.ts'] and 'web/index.ts' in d['files_with_calls_tied_again'], d"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

rm "$up/app/util.py"
check "update: a file removed: listed" "$(U); assert d['removed'] == ['app/util.py'] and d['added'] == [] and d['changed'] == [], d"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

for f in more/kinds/core/src/lib.rs more/kinds/web/shapes.ts more/goose/main.goose more/esm/main.js more/rules/app.py more/nested/python/mypkg/core.py; do
  if [ -f "$up/$f" ]; then
    top_line "$f" ''
    "$SW" update "$up" "$ug" >/dev/null 2>&1
    eq "update: a line added at the top of $f: the graph index builds" "$(as_index)" same
    sed -i '4,7d' "$up/$f"
    "$SW" update "$up" "$ug" >/dev/null 2>&1
    eq "update: lines 4 to 7 of $f taken out: the graph index builds" "$(as_index)" same
  else
    bad "update: the fixture file $f is not there"
  fi
done

eq "update: a call through a module the repo does not hold is a call out of the repo" "$(q "$ug" "select coalesce(c.note, 'no note') from calls c join files f on f.id = c.file_id where f.path = 'more/ext/use.py' and c.callee = 'build'")" external
mkdir "$up/gadgets"; echo 'export const a = 1;' > "$up/gadgets/x.ts"
check "update: a new folder at the top makes its name the repo's own: every call is tied again" "$(U); assert d['added'] == ['gadgets/x.ts'] and d['all_calls_tied_again'] is True and d['calls_tied_again'] == d['calls'], d"
eq "update: ... and gadgets.build() is no longer a call out of the repo" "$(q "$ug" "select coalesce(c.note, 'no note') from calls c join files f on f.id = c.file_id where f.path = 'more/ext/use.py' and c.callee = 'build'")" "no note"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

touch "$up/app/main.py"
check "update: a file touched and not changed is looked at and left alone" "$(U); assert d['looked_at'] >= 1 and d['changed'] == [] and d['calls_tied_again'] == 0, d"

touch -r "$up/more/ext/make.py" "$work/was"
printf 'def built(x):\n    return x\n' > "$up/more/ext/make.py"
touch -r "$work/was" "$up/more/ext/make.py"
check "update: a file changed and given back its size and its old time is still seen" "$(U); assert d['changed'] == ['more/ext/make.py'], d"
eq "update: ... and the graph is the one index builds" "$(as_index)" same

sleep 4
"$SW" update "$up" "$ug" >/dev/null
check "update: once file times have settled, an unchanged repo costs no read" "$(U); assert d['looked_at'] == 0 and d['changed'] == [], d"

"$SW" update "$up" "$ug" --resolution 3 >/dev/null
"$SW" index "$up" "$work/ref3.db" --resolution 3 >/dev/null
eq "update: --resolution groups the files again, as index does at that resolution" "$([ "$(dump "$ug")" = "$(dump "$work/ref3.db")" ] && echo same || echo different) $(q "$ug" "select value from meta where key = 'resolution'")" "same 300"

check "update: no graph there: it is built whole, and the answer says so" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','update','$up','$work/none.db','--resolution','3'])); assert d['built_whole'] is True and 'no graph' in d['why'] and 'files' in d['index'], d"
eq "update: ... the same graph" "$([ "$(dump "$work/none.db")" = "$(dump "$work/ref3.db")" ] && echo same || echo different)" same
cp "$ug" "$work/norules.db"; q "$work/norules.db" "delete from meta where key = 'rules'"
check "update: a graph from before rules were numbered is built whole" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','update','$up','$work/norules.db'])); assert d['built_whole'] is True and 'other rules' in d['why'], d"
cp "$work/kindsc.db" "$work/upc.db"
check "update: a graph holding compiler answers is built whole, and the answer says to run compiler again" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','update','tests/fixtures/kinds','$work/upc.db'])); assert d['built_whole'] is True and 'compiler' in d['why'], d"
check "update: a graph of another folder is built whole for this one" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','update','tests/fixtures/mini','$work/upc.db'])); assert d['built_whole'] is True and 'was of' in d['why'], d"
check "update: a folder that is not there is an error" "import subprocess; r=subprocess.run(['$SW','update','$work/nowhere','$work/upc.db'],capture_output=True,text=True); assert r.returncode != 0 and 'no such directory' in r.stderr, r.stderr"

# A name defined in more than 50 places is tied only within the caller's
# own file and the files it imports, so update redoes a change to one only
# in the files that import the changed file; at 50 or fewer, everywhere.
# 59 files that define run(), one (m00) that does not yet, a file that
# imports run from m00 and calls it, and one that calls run() with no import.
# (Each run() makes a call of its own, so that the calls of run are few
# among all: past two calls in five, update ties them all.)
cm="$work/common"; cg="$work/common.db"; mkdir -p "$cm/c"
for i in $(seq -w 1 59); do printf 'def run(x):\n    return len(x)\n' > "$cm/c/m$i.py"; done
printf 'def other(x):\n    return x\n' > "$cm/c/m00.py"
printf 'from c.m00 import run\n\n\ndef go():\n    return run(1)\n' > "$cm/c/user.py"
printf 'def go2():\n    return run(2)\n' > "$cm/c/loose.py"
"$SW" index "$cm" "$cg" >/dev/null
run_links() { q "$cg" "select coalesce((select group_concat(e.resolution || '>' || g.path, ' ') from call_edges e join symbols s on s.id = e.callee join files g on g.id = s.file_id where e.file_id = f.id), 'unlinked') from files f where f.path = '$1'"; }
UC() { "$SW" update "$cm" "$cg" > "$work/u.json" 2>"$work/u.err"; echo "import json; d=json.load(open('$work/u.json'))"; }
eq "update: a name defined in 59 places: the call of it through an import of a file that does not define it has no link" "$(run_links c/user.py)" unlinked
printf 'def other(x):\n    return x\n\n\ndef run(x):\n    return x\n' > "$cm/c/m00.py"
check "update: a 60th definition, in the imported file: the calls are tied again in that file and in the file that imports it, and nowhere else" "$(UC); assert d['changed'] == ['c/m00.py'] and d['files_with_calls_tied_again'] == ['c/m00.py', 'c/user.py'], d"
eq "update: ... and the importing file's call has its link" "$(run_links c/user.py)" "imported_name>c/m00.py"
eq "update: ... and the graph is the one index builds" "$(as_index_of "$cm" "$cg")" same
rm "$cm"/c/m5?.py
check "update: ten of the definitions removed, 50 left: every call of the name is tied again, wherever it is" "$(UC); assert len(d['removed']) == 10 and {'c/user.py', 'c/loose.py'} <= set(d['files_with_calls_tied_again']), d"
eq "update: ... and the graph is the one index builds" "$(as_index_of "$cm" "$cg")" same

# Past two calls in five, update ties every call again, as index does: the
# same links, sooner than tying a long list one statement at a time.
fw="$work/few"; fg="$work/few.db"; mkdir -p "$fw"
printf 'def a(x):\n    return b(x)\n\n\ndef b(x):\n    return len(x)\n' > "$fw/one.py"
printf 'def c(x):\n    return str(x)\n' > "$fw/two.py"
"$SW" index "$fw" "$fg" >/dev/null
printf '# a note\ndef a(x):\n    return b(x)\n\n\ndef b(x):\n    return len(x)\n' > "$fw/one.py"
check "update: a change that reaches most of the calls: all of them are tied again, and the answer says so" "import json,subprocess; d=json.loads(subprocess.check_output(['$SW','update','$fw','$fg'])); assert d['changed'] == ['one.py'] and d['all_calls_tied_again'] is True and d['calls_tied_again'] == d['calls'] == 3, d"
eq "update: ... and the graph is the one index builds" "$(as_index_of "$fw" "$fg")" same

# What index writes for a repo carries a number (RULES_NUMBER): update
# builds a graph whole when it was written under another. The fixtures'
# graphs are held to it here, so a change to a reader, a pattern or a link
# rule that alters them cannot go in with the number as it was.
rules_hash() { for x in mini kinds rules esm goose nested outside; do "$SW" index "tests/fixtures/$x" "$work/rh.db" >/dev/null; python3 tests/graph_dump.py "$work/rh.db"; done | sha256sum | cut -c1-16; }
eq "rules: the fixtures' graphs are those of this rules number (a reader, pattern or link rule changed them: raise RULES_NUMBER in src/store.goose and put '<number>:<hash>' here; only a fixture changed: the hash)" "$(sed -n 's/^let RULES_NUMBER = "\(.*\)";/\1/p' src/store.goose):$(rules_hash)" "1:8823e4165eb7e8c3"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
