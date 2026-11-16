// Facts from source, by syntax tree, never by running anything: definitions,
// imports and call sites, found with goose-treesitter's ast-grep style
// patterns on every core. A pattern matches one shape of code, so each
// language has a few variants (`fn` and `pub fn`, a return type or not).

import std;
import sqlite;
import treesitter;

// The folders a walk never enters: dependencies, caches, build output.
let SKIP_DIRS = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox",
                 ".mypy_cache", ".pytest_cache", "dist", "build", ".gradle", "obj", ".next",
                 ".spread-wings", ".swan"];

// The languages v0.1 extracts, as goose-treesitter names them.
fn supported(lang: const u8[:]) -> bool {
    return lang == "python" || lang == "typescript" || lang == "tsx" || lang == "javascript" || lang == "rust";
}

// "kind<TAB>capture<TAB>pattern" per line. kind "import" captures the
// module, "call" the callee, anything else names a definition.
fn patterns(lang: const u8[:]) -> const u8[:] {
    if lang == "python" {
        return """
function	NAME	def $NAME($$$A): $$$B
function	NAME	def $NAME($$$A) -> $R: $$$B
function	NAME	async def $NAME($$$A): $$$B
function	NAME	async def $NAME($$$A) -> $R: $$$B
class	NAME	class $NAME($$$A): $$$B
class	NAME	class $NAME: $$$B
import	M	import $M
import	M	from $M import $$$X
call	F	$F($$$A)
""";
    }
    if lang == "rust" {
        return """
function	NAME	fn $NAME($$$A) -> $R { $$$B }
function	NAME	fn $NAME($$$A) { $$$B }
function	NAME	pub fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub fn $NAME($$$A) { $$$B }
function	NAME	pub(crate) fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub(crate) fn $NAME($$$A) { $$$B }
function	NAME	async fn $NAME($$$A) -> $R { $$$B }
function	NAME	async fn $NAME($$$A) { $$$B }
function	NAME	pub async fn $NAME($$$A) -> $R { $$$B }
function	NAME	pub async fn $NAME($$$A) { $$$B }
struct	NAME	struct $NAME { $$$B }
struct	NAME	pub struct $NAME { $$$B }
struct	NAME	struct $NAME($$$B);
struct	NAME	pub struct $NAME($$$B);
enum	NAME	enum $NAME { $$$B }
enum	NAME	pub enum $NAME { $$$B }
trait	NAME	trait $NAME { $$$B }
trait	NAME	pub trait $NAME { $$$B }
impl	T	impl $T { $$$B }
impl	T	impl $TR for $T { $$$B }
mod	NAME	mod $NAME;
mod	NAME	pub mod $NAME;
import	P	use $P;
import	P	pub use $P;
call	F	$F($$$A)
""";
    }
    if lang == "javascript" {
        return """
function	NAME	function $NAME($$$A) { $$$B }
function	NAME	async function $NAME($$$A) { $$$B }
function	NAME	const $NAME = ($$$A) => $B
function	NAME	const $NAME = async ($$$A) => $B
class	NAME	class $NAME { $$$B }
class	NAME	class $NAME extends $S { $$$B }
import	M	require($M)
call	F	$F($$$A)
""";
    }
    // typescript, tsx
    return """
function	NAME	function $NAME($$$A) { $$$B }
function	NAME	function $NAME($$$A): $T { $$$B }
function	NAME	async function $NAME($$$A) { $$$B }
function	NAME	async function $NAME($$$A): $T { $$$B }
function	NAME	const $NAME = ($$$A) => $B
function	NAME	const $NAME = async ($$$A) => $B
class	NAME	class $NAME { $$$B }
class	NAME	class $NAME extends $S { $$$B }
class	NAME	class $NAME implements $$$I { $$$B }
interface	NAME	interface $NAME { $$$B }
import	M	require($M)
call	F	$F($$$A)
""";
}

// The capture named `name` from search_files' captures (name 0x1f text 0x1e).
fn capture(caps: const u8[:], name: const u8[:]) -> const u8[:] {
    var pos = 0;
    while pos < caps.len {
        let sep = find(caps[pos..], "\x1f");
        guard sep >= 0 else { break; }
        let end = find(caps[pos + sep + 1..], "\x1e");
        guard end >= 0 else { break; }
        if caps[pos..pos + sep] == name { return caps[pos + sep + 1..pos + sep + 1 + end]; }
        pos = pos + sep + 1 + end + 1;
    }
    return "";
}

fn ident_char(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

// The name a call reaches: the last identifier of `a.b.c`, `a::b`, `x?.y`,
// dropping generic arguments. "" when the callee isn't a plain name path
// (a call on a call, a closure, an index).
fn callee_name(f: const u8[:]) -> const u8[:] {
    var end = f.len;
    if end > 0 && f[end - 1] == '>' {
        let lt = find(f, "<");
        if lt > 0 { end = lt; }
    }
    if end >= 2 && f[end - 2] == ':' && f[end - 1] == ':' { end = end - 2; }   // `f::<T>`
    var i = end;
    while i > 0 && ident_char(f[i - 1]) { i--; }
    guard i < end else { return ""; }
    let c = f[i];
    guard !(c >= '0' && c <= '9') else { return ""; }
    return f[i..end];
}

// The module an import names, quotes and braces trimmed: `"./m"` -> `./m`,
// `crate::state::{A, B}` -> `crate::state`.
fn module_name(m: const u8[:]) -> const u8[:] {
    var s = trim(m);
    if s.len >= 2 && (s[0] == '"' || s[0] == '\'' || s[0] == '`') { s = s[1..s.len - 1]; }
    let brace = find(s, "::{");
    if brace > 0 { s = s[..brace]; }
    return s;
}

struct Def { file: i64, start: i64, end: i64, id: i64 }

extern fn sw_is_symlink(path: const u8[:]) -> bool;

let LANGS = ["python", "typescript", "tsx", "javascript", "rust"];

// Walks repo, parses every supported file and writes its facts. Returns
// the number of files indexed.
fn extract_repo(db: i64, repo: const u8[:]) -> i64 {
    // Every file found: its absolute path and language, one per line each, and its row id.
    var paths: u8[>..] = [];
    var plangs: u8[>..] = [];
    var pids: i64[>..] = [];
    let ins_file = sqlite::prepare_or_die(db, "INSERT INTO files (path, lang, dir) VALUES (?1, ?2, ?3)");
    var dirs: u8[>..] = [];
    dirs.append(repo);
    dirs.push('\n');
    var next = 0;
    while next < dirs.len && pids.len < 200000 {
        let end = next + find(dirs[next..], "\n");
        var dir: u8[>..] = [];
        dir.append(dirs[next..end]);
        next = end + 1;
        var names: u8[>..] = [];
        guard list_dir(dir, names) else { continue; }
        each_split(names, '\n') { name =>
            guard name.len > 0;
            var full: u8[>..] = [];
            format(full, dir, "/", name);
            if is_dir(full) {
                // Hidden folders (.git, .tools, .github, .cache) hold tooling, not the code.
                if name[0] != '.' && !contains(SKIP_DIRS, name) && !sw_is_symlink(full) { dirs.append(full); dirs.push('\n'); }
            } else {
                let lang = treesitter::language_of_path(full);
                if supported(lang) && !sw_is_symlink(full) {
                    let rel = full[repo.len + 1..];
                    let slash = rfind(rel, "/");
                    sqlite::reset(ins_file);
                    sqlite::bind_text(ins_file, 1, rel);
                    sqlite::bind_text(ins_file, 2, lang);
                    sqlite::bind_text(ins_file, 3, if slash >= 0 { rel[..slash] } else { "." });
                    sqlite::step_done(ins_file);
                    pids.push(sqlite::last_rowid(db));
                    paths.append(full);
                    paths.push('\n');
                    plangs.append(lang);
                    plangs.push('\n');
                }
            }
        };
    }
    sqlite::finalize(ins_file);
    let all_paths = split(paths, '\n');
    let all_langs = split(plangs, '\n');

    // Every file goes to a pool of worker threads, one per hardware thread,
    // taking files from one queue as they finish (a big file doesn't hold
    // the rest up). A worker parses its file once and runs all of the
    // language's patterns on that tree. Results come back as records and are
    // written here, in file order, so the graph is the same every run.
    for i in 0..pids.len {
        var job = FileJob { idx: i, .. };
        job.path.append(all_paths[i]);
        job.lang.append(all_langs[i]);
        qput(job);
    }
    let workers = max(1, min(hardware_threads(), pids.len));
    for w in 0..workers { qput(FileJob { idx: -1, .. }); }
    var tids: i64[>..] = [];
    for w in 0..workers { tids.push(thread_spawn(extract_worker)); }
    var all: u8[>..] = [];
    var at: i64[>..] = [];
    var len: i64[>..] = [];
    at.resize(pids.len, 0);
    len.resize(pids.len, 0);
    for k in 0..pids.len {
        let d = qget<FileDone>();
        at[d.idx] = all.len;
        len[d.idx] = d.data.len;
        all.append(d.data);
    }
    for t in tids { thread_wait(t); }

    let ins_sym = sqlite::prepare_or_die(db, "INSERT INTO symbols (file_id, name, kind, row, start, end_, end_row, sig) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
    let ins_imp = sqlite::prepare_or_die(db, "INSERT INTO imports (file_id, module, row, names) VALUES (?1, ?2, ?3, ?4)");
    let ins_call = sqlite::prepare_or_die(db, "INSERT INTO calls (file_id, row, start, callee, in_symbol, text) VALUES (?1, ?2, ?3, ?4, 0, ?5)");
    for i in 0..pids.len {
        let fid = pids[i];
        // Records: kind 0x1f a 0x1f b 0x1f start 0x1f end 0x1f row 0x1e
        each_split(all[at[i]..at[i] + len[i]], 0x1e) { rec =>
            let f = split(rec, 0x1f);
            guard f.len == 6;
            let st, ok1 = parse_int(f[3]);
            let en, ok2 = parse_int(f[4]);
            let row, ok3 = parse_int(f[5]);
            guard ok1 && ok2 && ok3;
            if f[0] == "import" {
                sqlite::reset(ins_imp);
                sqlite::bind_int(ins_imp, 1, fid);
                sqlite::bind_text(ins_imp, 2, f[1]);
                sqlite::bind_int(ins_imp, 3, row);
                sqlite::bind_text(ins_imp, 4, f[2]);
                sqlite::step_done(ins_imp);
            } else if f[0] == "call" {
                sqlite::reset(ins_call);
                sqlite::bind_int(ins_call, 1, fid);
                sqlite::bind_int(ins_call, 2, row);
                sqlite::bind_int(ins_call, 3, st);
                sqlite::bind_text(ins_call, 4, f[1]);
                sqlite::bind_text(ins_call, 5, f[2]);
                sqlite::step_done(ins_call);
            } else {
                sqlite::reset(ins_sym);
                sqlite::bind_int(ins_sym, 1, fid);
                sqlite::bind_text(ins_sym, 2, f[1]);
                sqlite::bind_text(ins_sym, 3, f[0]);
                sqlite::bind_int(ins_sym, 4, row);
                sqlite::bind_int(ins_sym, 5, st);
                sqlite::bind_int(ins_sym, 6, en);
                // b is "<end row> <signature line>"
                let sp = find(f[2], " ");
                let er, er_ok = parse_int(if sp > 0 { f[2][..sp] } else { f[2] });
                sqlite::bind_int(ins_sym, 7, if er_ok { er } else { row });
                sqlite::bind_text(ins_sym, 8, if sp > 0 { f[2][sp + 1..] } else { "" });
                sqlite::step_done(ins_sym);
            }
        };
    }
    sqlite::finalize(ins_sym);
    sqlite::finalize(ins_imp);
    sqlite::finalize(ins_call);
    // Two patterns can match one definition (a const arrow and a call can
    // overlap): keep one row per place.
    sqlite::exec_or_die(db, """
        DELETE FROM symbols WHERE id NOT IN (
            SELECT MIN(id) FROM symbols GROUP BY file_id, start, name);
        -- A method's container: the innermost class, struct, trait, interface
        -- or impl that spans it.
        UPDATE symbols SET container = (
            SELECT c.name FROM symbols c
            WHERE c.file_id = symbols.file_id AND c.id != symbols.id
              AND c.kind IN ('class', 'struct', 'trait', 'interface', 'impl')
              AND c.start <= symbols.start AND symbols.end_ <= c.end_
            ORDER BY c.end_ - c.start LIMIT 1)
        WHERE kind = 'function';
        -- A call site sits in the innermost definition that spans it.
        UPDATE calls SET in_symbol = COALESCE((
            SELECT s.id FROM symbols s
            WHERE s.file_id = calls.file_id AND s.start <= calls.start AND calls.start < s.end_
              AND s.kind IN ('function', 'impl')
            ORDER BY s.end_ - s.start LIMIT 1), 0);
        -- A definition's own text also matches the call pattern in some
        -- grammars; a call at a definition's exact start is not one.
        DELETE FROM calls WHERE EXISTS (
            SELECT 1 FROM symbols s WHERE s.file_id = calls.file_id AND s.start = calls.start);
    """);
    return pids.len;
}

struct FileJob { idx: i64, lang: u8[..16], path: u8[>..] }
struct FileDone { idx: i64, data: u8[>..] }

fn record(out: u8[>..]&, kind: const u8[:], a: const u8[:], b: const u8[:], start: i64, end: i64, row: i64) {
    format(out, kind, "\x1f", a, "\x1f", b, "\x1f", start, "\x1f", end, "\x1f", row);
    out.push(0x1e);
}

// Matches the compiled pattern against the tree the worker already loaded
// (treesitter's t_nodes), so one parse serves every pattern.
fn search_loaded<F>() {
    for i in 0..treesitter::t_nodes.len / treesitter::R {
        treesitter::nb = 0;
        if (treesitter::flags(treesitter::t_nodes, i) & treesitter::F_EXTRA) == 0 && treesitter::match_node(treesitter::p_root, i) { F(i); }
    }
}

// The captures of the current match as name 0x1f text 0x1e.
fn current_captures(out: u8[>..]&) {
    treesitter::each_binding() { name, text =>
        out.append(name);
        out.push(0x1f);
        out.append(text);
        out.push(0x1e);
    };
}

// The local names an import statement binds, comma-separated: `a, b as c`
// gives `a,c`; braces and `*` are skipped.
fn import_names(raw: const u8[:], out: u8[>..]&) {
    each_split(raw, ',') { part =>
        var p = trim(part);
        while p.len > 0 && (p[0] == '{' || p[0] == '(') { p = trim(p[1..]); }
        while p.len > 0 && (p[p.len - 1] == '}' || p[p.len - 1] == ')') { p = trim(p[..p.len - 1]); }
        let as_at = find(p, " as ");
        let name = if as_at > 0 { trim(p[as_at + 4..]) } else { p };
        // `a::b::C` binds C
        let last = rfind(name, "::");
        let n2 = if last >= 0 { name[last + 2..] } else { name };
        if n2.len > 0 && n2 != "*" && n2 != "self" && callee_name(n2) == n2 {
            if out.len > 0 { out.push(','); }
            out.append(n2);
            // `from pkg import mod as x` also records `mod>x`, so the link
            // step can bind x to pkg/mod.
            if as_at > 0 {
                let orig = trim(p[..as_at]);
                if orig.len > 0 && callee_name(orig) == orig { format(out, ",", orig, ">", n2); }
            }
        }
    };
}

thread_fn extract_worker() {
    loop {
        let job = qget<FileJob>();
        guard job.idx >= 0 else { break; }
        var done = FileDone { idx: job.idx, .. };
        var text: u8[>..] = [];
        if read_file(job.path, text) {
            treesitter::t_text.clear();
            treesitter::t_text.append(text);
            if treesitter::parse(job.lang, treesitter::t_text, treesitter::t_nodes) {
                each_split(patterns(job.lang), '\n') { line =>
                    let f = split(line, '\t');
                    if f.len == 3 {
                        var why: u8[>..] = [];
                        if treesitter::compile(job.lang, f[2], why) {
                            search_loaded() { node =>
                                var caps: u8[>..] = [];
                                current_captures(caps);
                                let text = capture(caps, f[1]);
                                let st = treesitter::match_start(node);
                                let en = treesitter::match_end(node);
                                let row = treesitter::match_row(node) + 1;
                                if text.len > 0 {
                                    if f[0] == "mod" {
                                        record(done.data, "import", str("mod::", text), "", st, en, row);
                                    } else if f[0] == "import" {
                                        var names: u8[>..] = [];
                                        let t = trim(text);
                                        // The names after `import`, from the statement's own text
                                        // (a `$$$X` capture can come back empty here).
                                        let stmt = treesitter::match_text(node);
                                        let imp_at = find(stmt, " import ");
                                        let after = if imp_at >= 0 { stmt[imp_at + 8..] } else { "" };
                                        if job.lang == "python" && only_dots(t) {
                                            // `from . import a, b`: the modules a and b, beside this file.
                                            each_split(after, ',') { x =>
                                                names.clear();
                                                import_names(x, names);
                                                if names.len > 0 { record(done.data, "import", str(t, names), "", st, en, row); }
                                            };
                                        } else {
                                            if job.lang == "python" { import_names(after, names); }
                                            if job.lang == "python" && imp_at < 0 {
                                                // `import a.b as x`: the module a.b, bound to the name x.
                                                let as_at = find(t, " as ");
                                                if as_at > 0 {
                                                    names.clear();
                                                    names.push('@');
                                                    names.append(trim(t[as_at + 4..]));
                                                    record(done.data, "import", trim(t[..as_at]), names, st, en, row);
                                                    names.clear();
                                                    names.append("-");
                                                }
                                            }
                                            if job.lang == "rust" {
                                                let brace = find(t, "::{");
                                                if brace > 0 { import_names(t[brace + 3..], names); }
                                                else { import_names(t, names); }
                                            }
                                            let m = module_name(text);
                                            if m.len > 0 && names != "-" { record(done.data, "import", m, names, st, en, row); }
                                        }
                                    } else if f[0] == "call" {
                                        let c = callee_name(text);
                                        if c.len > 0 { record(done.data, "call", c, one_line(text, 120), st, en, row); }
                                    } else {
                                        let name = callee_name(text);
                                        if name.len > 0 {
                                            let end_row = row + count_newlines(treesitter::match_text(node));
                                            record(done.data, f[0], name, str(end_row, " ", one_line(treesitter::match_text(node), 200)), st, en, row);
                                        }
                                    }
                                }
                            };
                        }
                    }
                };
            }
            // ES modules: `import ... from "m"`, `import "m"`, `export ... from "m"`,
            // read from the text (a pattern can't hold the module string).
            if job.lang == "typescript" || job.lang == "tsx" || job.lang == "javascript" {
                var row = 0;
                each_split(text, '\n') { raw =>
                    row++;
                    let line = trim(raw);
                    if starts_with(line, "import ") || starts_with(line, "import\"") || starts_with(line, "import'") || starts_with(line, "export ") {
                        var at = find(line, " from ");
                        if at >= 0 { at = at + 6; } else if starts_with(line, "import") { at = 6; } else { at = -1; }
                        if at >= 0 {
                            let rest = trim(line[at..]);
                            if rest.len >= 2 && (rest[0] == '"' || rest[0] == '\'') {
                                let close = find(rest[1..], rest[..1]);
                                if close > 0 {
                                    // The names: `import a, { b, c as d } from` gives a,b,d.
                                    var names: u8[>..] = [];
                                    let head_end = find(line, " from ");
                                    if head_end > 7 && starts_with(line, "import ") {
                                        var head = trim(line[7..head_end]);
                                        if starts_with(head, "type ") { head = trim(head[5..]); }
                                        if starts_with(head, "* as ") { names.push('@'); names.append(trim(head[5..])); }
                                        else { import_names(head, names); }
                                    }
                                    record(done.data, "import", rest[1..1 + close], names, 0, 0, row);
                                }
                            }
                        }
                    }
                };
            }
        }
        qput(done);
    }
}

// The first line of s, at most n bytes, with no record separators.
fn one_line(s: const u8[:], n: i64) -> u8[>..] {
    var out: u8[>..] = [];
    for c in s {
        if c == '\n' || out.len >= n { break; }
        out.push(if c == 0x1e || c == 0x1f || c == '\r' { ' ' } else { c });
    }
    return out;
}

fn count_newlines(s: const u8[:]) -> i64 {
    var n: i64 = 0;
    for c in s { if c == '\n' { n++; } }
    return n;
}

fn only_dots(s: const u8[:]) -> bool {
    for c in s { if c != '.' { return false; } }
    return true;
}

fn trim_nul(s: const u8[:]) -> const u8[:] {
    var n = s.len;
    while n > 0 && s[n - 1] == 0 { n--; }
    return s[..n];
}
